package bootstrap

import (
	"context"
	"errors"
	"reflect"
	"testing"

	"github.com/gatework/net-connector/config"
	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/fleet"
)

func TestPolicyDoesNotResolveCredentials(t *testing.T) {
	s, e := config.Load(context.Background(), config.Options{Name: "backup", CWD: t.TempDir(), Home: t.TempDir(), Directories: []string{}, Defaults: config.Defaults("backup")})
	if e != nil {
		t.Fatal(e)
	}
	calls := 0
	r := func(string) string { calls++; return "" }
	p, e := New(s, r)
	if e != nil || calls != 0 {
		t.Fatal(e, calls)
	}
	_, e = p.DeviceWithLogger(context.Background(), fleet.Record{Host: "192.0.2.1", Platform: "h3c"}, nil)
	if !errors.Is(e, ErrCredentials) || calls == 0 {
		t.Fatal(e, calls)
	}
}

func TestResolvedSettingsDoNotInventMissingBatchDefaults(t *testing.T) {
	defaults := config.Defaults("backup")
	delete(defaults["backup"].(map[string]any), "parallel")
	policy, err := config.Load(context.Background(), config.Options{Name: "backup", CWD: t.TempDir(), Home: t.TempDir(), Directories: []string{}, Defaults: defaults})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = resolveSettings(policy); err == nil {
		t.Fatal("missing batch parallel default was silently restored by bootstrap")
	}
}

func TestFrozenLogDirectoryModes(t *testing.T) {
	for _, explicit := range []string{"", "/explicit/logs"} {
		env := map[string]string{}
		if explicit != "" {
			env["NC_LOG_DIRECTORY"] = explicit
		}
		policy, err := config.Load(context.Background(), config.Options{Name: "backup", CWD: t.TempDir(), Home: t.TempDir(), Directories: []string{}, Defaults: config.Defaults("backup"), Environment: env})
		if err != nil {
			t.Fatal(err)
		}
		s, err := New(policy, nil)
		if err != nil {
			t.Fatal(err)
		}
		for _, tc := range []struct{ mode, want string }{{"backup", ""}, {"tftp", "/batch/logs"}, {"topology", "/batch/logs"}} {
			want := tc.want
			if explicit != "" {
				want = explicit
			}
			if got := s.LogDirectory(tc.mode, "/batch"); got != want {
				t.Errorf("%s: %q want %q", tc.mode, got, want)
			}
		}
	}
}

func TestDeviceTemplateDoesNotRetainHostOrSecrets(t *testing.T) {
	policy, err := config.Load(context.Background(), config.Options{Name: "backup", CWD: t.TempDir(), Home: t.TempDir(), Directories: []string{}, Defaults: config.Defaults("backup")})
	if err != nil {
		t.Fatal(err)
	}
	username := "first"
	services, err := New(policy, func(key string) string {
		if key == "NC_DEVICE_USERNAME" {
			return username
		}
		return ""
	})
	if err != nil {
		t.Fatal(err)
	}
	var got []connector.ConnectionConfig
	services = services.WithDeviceFactory(func(_ connector.Driver, c connector.ConnectionConfig) (*connector.Device, error) {
		got = append(got, c)
		return nil, nil
	})
	for _, host := range []string{"192.0.2.1", "192.0.2.2"} {
		if _, err = services.DeviceWithLogger(t.Context(), fleet.Record{Host: host, Platform: "h3c"}, nil); err != nil {
			t.Fatal(err)
		}
		username = "second"
	}
	if got[0].Host != "192.0.2.1" || got[1].Host != "192.0.2.2" || got[0].Username != "first" || got[1].Username != "second" {
		t.Fatal(got)
	}
	if c := services.templates["h3c"]; c.Host != "" || c.Username != "" || c.Password != "" {
		t.Fatal("template retained per-device credentials")
	}
}

func TestCredentialKeysPreferVendorThenShared(t *testing.T) {
	keys := credentialKeys("huawei")
	want := deviceCredentialKeys{
		username:       []string{"NC_HUAWEI_USERNAME", "NC_DEVICE_USERNAME"},
		password:       []string{"NC_HUAWEI_PASSWORD", "NC_DEVICE_PASSWORD"},
		enablePassword: []string{"NC_HUAWEI_ENABLE_PASSWORD", "NC_ENABLE_PASSWORD"},
	}
	if !reflect.DeepEqual(keys, want) {
		t.Fatalf("credential keys = %#v", keys)
	}
}

func TestJumpHostAndRetriesReachConnection(t *testing.T) {
	load := func(env map[string]string) (*Services, error) {
		p, err := config.Load(context.Background(), config.Options{Name: "backup", CWD: t.TempDir(), Home: t.TempDir(), Directories: []string{}, Environment: env, Defaults: config.Defaults("backup"), AllowMissing: true})
		if err != nil {
			return nil, err
		}
		return New(p, func(string) string { return "operator" })
	}
	services, err := load(map[string]string{"NC_SSH_JUMP_HOST": "ops@bastion.example:2222", "NC_SSH_CONNECT_RETRIES": "3"})
	if err != nil {
		t.Fatal(err)
	}
	var got connector.ConnectionConfig
	services = services.WithDeviceFactory(func(_ connector.Driver, c connector.ConnectionConfig) (*connector.Device, error) {
		got = c
		return nil, nil
	})
	if _, err = services.DeviceWithLogger(t.Context(), fleet.Record{Host: "192.0.2.1", Platform: "h3c"}, nil); err != nil {
		t.Fatal(err)
	}
	if got.JumpHost != "ops@bastion.example:2222" || got.ConnectRetries != 3 {
		t.Fatalf("connection = %+v", got)
	}
	defaults, err := load(map[string]string{})
	if err != nil {
		t.Fatal(err)
	}
	defaults = defaults.WithDeviceFactory(func(_ connector.Driver, c connector.ConnectionConfig) (*connector.Device, error) {
		got = c
		return nil, nil
	})
	if _, err = defaults.DeviceWithLogger(t.Context(), fleet.Record{Host: "192.0.2.1", Platform: "h3c"}, nil); err != nil || got.ConnectRetries != 1 || got.JumpHost != "" {
		t.Fatalf("defaults = %+v %v", got, err)
	}
	if _, err = load(map[string]string{"NC_SSH_JUMP_HOST": "-oProxyCommand=x"}); err == nil {
		t.Fatal("option injection accepted")
	}
}

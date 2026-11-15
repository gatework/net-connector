package bootstrap

import (
	"context"
	"testing"

	"github.com/gatework/net-connector/config"
	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/fleet"
)

func TestSessionObserversAreBoundPerServicesCopy(t *testing.T) {
	policy, err := config.Load(context.Background(), config.Options{Name: "backup", CWD: t.TempDir(), Home: t.TempDir(), Directories: []string{}, Defaults: config.Defaults("backup")})
	if err != nil {
		t.Fatal(err)
	}
	base, err := New(policy, func(key string) string {
		if key == "NC_DEVICE_USERNAME" {
			return "fixture"
		}
		return ""
	})
	if err != nil {
		t.Fatal(err)
	}
	var configs []connector.ConnectionConfig
	base = base.WithDeviceFactory(func(_ connector.Driver, c connector.ConnectionConfig) (*connector.Device, error) {
		configs = append(configs, c)
		return nil, nil
	})
	observed := 0
	scoped := base.WithSessionObserver(func(context.Context, connector.SessionEvent) error { observed++; return nil })
	for _, services := range []*Services{scoped, base} {
		if _, err = services.DeviceWithLogger(t.Context(), fleet.Record{Host: "192.0.2.1", Platform: "h3c"}, nil); err != nil {
			t.Fatal(err)
		}
	}
	if configs[0].OnSessionEvent == nil || configs[1].OnSessionEvent != nil || base.templates["h3c"].OnSessionEvent != nil {
		t.Fatal("observer leaked into shared services/template")
	}
	if err = configs[0].OnSessionEvent(t.Context(), connector.SessionEvent{}); err != nil || observed != 1 {
		t.Fatal(err, observed)
	}
}

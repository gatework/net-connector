package cli

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/creack/pty"

	"github.com/gatework/net-connector/config"
	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/internal/bootstrap"
	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/netdisco"
)

type failingWriter struct{}

func (failingWriter) Write([]byte) (int, error) { return 0, errors.New("closed output") }

type cancelingWriter struct{ cancel context.CancelFunc }

func (w cancelingWriter) Write([]byte) (int, error) {
	w.cancel()
	return 0, errors.New("closed output")
}

func tftpReportFixture(ctx context.Context, t *testing.T, output io.Writer, progress io.Writer) (int, string) {
	t.Helper()
	r, _, _ := fixtureRuntime(t)
	r.Args = []string{"backup", "tftp", "--success-policy", "selected", "--tftp-server", "192.0.2.9", "--username", "user", "--password", "secret", "--json"}
	r.Output, r.Error = output, progress
	r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) {
		return []inventory.Device{{IP: "192.0.2.1", Name: "edge", Vendor: "cisco", OS: "nxos"}}, nil
	})
	r.DeviceFactory = func(_ connector.Driver, c connector.ConnectionConfig) (*connector.Device, error) {
		return connector.New(connector.StaticDriver{Grammar: connector.Terminal{Name: "cisco_nxos", LoginPrompt: testPattern(`sw#\s*$`), CommandPrompt: testPattern(`sw#\s*$`)}}, c, connector.WithTransportFactory(func(context.Context, connector.ConnectionConfig) (io.ReadWriteCloser, error) {
			a, b := net.Pipe()
			go func() {
				defer b.Close()
				_, _ = io.WriteString(b, "sw#")
				line, err := bufio.NewReader(b).ReadString('\n')
				if err != nil {
					return
				}
				_, _ = io.WriteString(b, line+"123 bytes copied\r\nsw#")
				_, _ = io.Copy(io.Discard, b)
			}()
			return a, nil
		}))
	}
	code := r.Run(ctx)
	return code, filepath.Join(r.CWD, "backups")
}

func latestReport(t *testing.T, root string) map[string]any {
	t.Helper()
	entries, err := os.ReadDir(root)
	if err != nil || len(entries) != 1 {
		t.Fatalf("batch directory: %v, %d entries", err, len(entries))
	}
	data, err := os.ReadFile(filepath.Join(root, entries[0].Name(), "report.json"))
	if err != nil {
		t.Fatal(err)
	}
	var report map[string]any
	if err := json.Unmarshal(data, &report); err != nil {
		t.Fatal(err)
	}
	return report
}

func TestProgressFailureKeepsCompletedTransferAndEvent(t *testing.T) {
	var output bytes.Buffer
	code, root := tftpReportFixture(t.Context(), t, &output, failingWriter{})
	if code != 1 {
		t.Fatal(code, output.String())
	}
	report := latestReport(t, root)
	if report["success"] != false || report["report_error"] != "progress_failed" {
		t.Fatal(report)
	}
	row := report["devices"].([]any)[0].(map[string]any)
	if row["status"] != "succeeded" || row["outcome"] != "uploaded" {
		t.Fatal(row)
	}
	events, err := filepath.Glob(filepath.Join(root, "*", "events.jsonl"))
	if err != nil || len(events) != 1 {
		t.Fatal(err, events)
	}
	data, err := os.ReadFile(events[0])
	if err != nil || !bytes.Contains(data, []byte(`"outcome":"uploaded"`)) {
		t.Fatal(err, string(data))
	}
}

func TestCanceledReportOutputRetains130AndDiagnostic(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	code, root := tftpReportFixture(ctx, t, cancelingWriter{cancel}, io.Discard)
	if code != 130 {
		t.Fatal(code)
	}
	report := latestReport(t, root)
	if report["success"] != false || report["report_error"] == nil {
		t.Fatal(report)
	}
}

func TestTopologyTFTPRejectedBeforeInputOrInventory(t *testing.T) {
	r, _, _ := fixtureRuntime(t)
	r.Args = []string{"topology", "plan", "--tftp", "--stdin-credentials"}
	r.Environment = map[string]string{"NC_CONFIG": "/does/not/exist"}
	r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) { t.Fatal("inventory accessed"); return nil, nil })
	if code := r.Run(t.Context()); code != 2 {
		t.Fatal(code)
	}
}

func TestTopologyPolicyPreflightBeforeCredentialsAndInventory(t *testing.T) {
	for _, env := range []map[string]string{{"NC_TOPOLOGY_DESCRIPTION_FORMAT": "%{unknown}"}} {
		r, _, _ := fixtureRuntime(t)
		r.Args = []string{"topology", "plan", "--stdin-credentials"}
		r.Environment = env
		r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) { t.Fatal("inventory accessed"); return nil, nil })
		if code := r.Run(t.Context()); code != 2 {
			t.Fatal(env, code)
		}
	}
}

func TestInteractiveSetupConsentAndCustomization(t *testing.T) {
	for _, tc := range []struct {
		name, args, answers string
		wantCode            int
		config, env         bool
	}{
		{"refuse_required", "consent", "n\n", 1, false, false},
		{"approve_config_refuse_env_customization", "consent", "y\nn\nn\n", 0, true, false},
		{"init_decline_customization", "config init --interactive", "n\n", 0, true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := t.TempDir()
			master, slave, err := pty.Open()
			if err != nil {
				t.Fatal(err)
			}
			defer master.Close()
			defer slave.Close()
			if _, err := master.Write([]byte(tc.answers)); err != nil {
				t.Fatal(err)
			}
			r := Runtime{Args: strings.Fields(tc.args), CWD: root, Home: root, Directories: []string{}, Environment: map[string]string{}, Input: slave, Error: slave, Output: &bytes.Buffer{}}
			code := 0
			if tc.args == "consent" {
				policy, e := config.Load(context.Background(), config.Options{Name: "backup", CWD: root, Home: root, Directories: []string{}, Environment: map[string]string{}, Defaults: config.Defaults("backup"), AllowMissing: true})
				if e != nil {
					t.Fatal(e)
				}
				reader := bufio.NewReader(slave)
				createConfig, createEnv, e := r.setupConsent(policy, reader)
				if errors.Is(e, errSetupDeclined) {
					code = 1
				} else if e != nil {
					t.Fatal(e)
				} else {
					if createConfig {
						policy, e = r.configure(t.Context(), policy, options{mode: "backup"}, "backup", reader)
					}
					if e == nil {
						_, e = config.InitializeSelected(policy, "backup", createConfig, createEnv)
					}
					if e != nil {
						t.Fatal(e)
					}
				}
			} else {
				code = r.Run(t.Context())
			}
			if code != tc.wantCode {
				t.Fatal(code)
			}
			configPath := filepath.Join(root, ".config", "net-connector", "net-connector.yml")
			envPath := filepath.Join(root, ".config", "net-connector", ".env")
			for _, item := range []struct {
				path string
				want bool
			}{{configPath, tc.config}, {envPath, tc.env}} {
				_, err := os.Lstat(item.path)
				if (err == nil) != item.want {
					t.Fatalf("%s: %v", item.path, err)
				}
			}
		})
	}
}

func TestInteractiveExistingFilesContinuesWithoutTerminal(t *testing.T) {
	r, _, _ := fixtureRuntime(t)
	r.Args = []string{"config", "init", "--non-interactive"}
	if code := r.Run(t.Context()); code != 0 {
		t.Fatal(code)
	}
	var output, diagnostics bytes.Buffer
	r.Args = []string{"inventory", "list"}
	r.Input, r.Output, r.Error = panicReader{}, &output, &diagnostics
	reads := 0
	r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) {
		reads++
		return []inventory.Device{{IP: "192.0.2.1", Vendor: "cisco", OS: "ios"}}, nil
	})
	if code := r.Run(t.Context()); code != 0 || reads != 1 {
		t.Fatalf("code=%d reads=%d diagnostics=%s", code, reads, diagnostics.String())
	}
}

func TestInitInteractiveExistingFilesNeedsNoTerminal(t *testing.T) {
	r, _, _ := fixtureRuntime(t)
	r.Args = []string{"config", "init", "--non-interactive"}
	if code := r.Run(t.Context()); code != 0 {
		t.Fatal(code)
	}
	configPath := filepath.Join(r.Home, ".config", "net-connector", "net-connector.yml")
	envPath := filepath.Join(r.Home, ".config", "net-connector", ".env")
	before := map[string][]byte{}
	for _, path := range []string{configPath, envPath} {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		before[path] = data
	}
	r.Args = []string{"config", "init", "--interactive"}
	r.Input = panicReader{}
	r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) { t.Fatal("inventory accessed"); return nil, nil })
	if code := r.Run(t.Context()); code != 0 {
		t.Fatal(code)
	}
	for path, old := range before {
		data, err := os.ReadFile(path)
		if err != nil || !bytes.Equal(data, old) {
			t.Fatal(path, err)
		}
	}
}

func TestInteractiveDeclinedOptionalEnvContinues(t *testing.T) {
	r, _, _ := fixtureRuntime(t)
	r.Args = []string{"config", "init", "--non-interactive"}
	if code := r.Run(t.Context()); code != 0 {
		t.Fatal(code)
	}
	envPath := filepath.Join(r.Home, ".config", "net-connector", ".env")
	if err := os.Remove(envPath); err != nil {
		t.Fatal(err)
	}
	master, slave, err := pty.Open()
	if err != nil {
		t.Fatal(err)
	}
	defer master.Close()
	defer slave.Close()
	if _, err := master.Write([]byte("n\n")); err != nil {
		t.Fatal(err)
	}
	// Drain the terminal: progress output written to slave would otherwise
	// fill the PTY buffer and block the run.
	drained := make(chan struct{})
	go func() {
		defer close(drained)
		_, _ = io.Copy(io.Discard, master)
	}()
	// Closing the slave ends the master read; closing the master does not on macOS.
	defer func() { _ = slave.Close(); <-drained }()
	r.Args, r.Input, r.Error = []string{"inventory", "list"}, slave, slave
	policy, e := config.Load(context.Background(), config.Options{Name: "backup", CWD: r.CWD, Home: r.Home, Directories: []string{}, Environment: map[string]string{}, Defaults: config.Defaults("backup"), AllowMissing: true})
	if e != nil {
		t.Fatal(e)
	}
	createConfig, createEnv, e := r.setupConsent(policy, bufio.NewReader(slave))
	if e != nil || createConfig || createEnv {
		t.Fatal(createConfig, createEnv, e)
	}
	reads := 0
	r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) {
		reads++
		return []inventory.Device{{IP: "192.0.2.1", Vendor: "cisco", OS: "ios"}}, nil
	})
	if code := r.Run(t.Context()); code != 0 || reads != 1 {
		t.Fatalf("code=%d reads=%d", code, reads)
	}
	if _, err := os.Lstat(envPath); !os.IsNotExist(err) {
		t.Fatal("optional .env created", err)
	}
}

func TestHelpExamplesAreDistinctAndOffline(t *testing.T) {
	views := map[string]string{}
	for _, action := range []string{"plan", "apply"} {
		r, out, _ := fixtureRuntime(t)
		r.Args = []string{"topology", action, "--help"}
		if code := r.Run(t.Context()); code != 0 {
			t.Fatal(action, code)
		}
		views[action] = out.String()
	}
	if views["plan"] == views["apply"] || !strings.Contains(views["apply"], "topology apply") || !strings.Contains(views["apply"], "示例") {
		t.Fatal(views)
	}
}

func TestTopologyCancelWinsOverBrokenOutput(t *testing.T) {
	r, _, _ := fixtureRuntime(t)
	r.Args = []string{"inventory", "list", "--for", "topology", "--json"}
	r.Output = failingWriter{}
	r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) {
		return []inventory.Device{{IP: "192.0.2.1", Vendor: "cisco", OS: "ios"}}, nil
	})
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if code := r.Run(ctx); code != 130 {
		t.Fatal(code)
	}
}

func TestTopologyCacheModeSelection(t *testing.T) {
	root := t.TempDir()
	for _, tc := range []struct {
		args []string
		want string
	}{
		{nil, "only"},
		{[]string{"--cache-mode", "refresh"}, "refresh"},
		{[]string{"--cache-only"}, "only"},
		{[]string{"--refresh-inventory"}, "refresh"},
	} {
		var helpErr error
		rootCommand := (Runtime{Input: panicReader{}, Output: io.Discard, Error: io.Discard}).commandTree(t.Context(), &helpErr)
		command, remaining, err := rootCommand.Find(append([]string{"topology", "plan"}, tc.args...))
		if err != nil {
			t.Fatal(err)
		}
		if err = command.ParseFlags(remaining); err != nil {
			t.Fatal(err)
		}
		o := options{mode: "topology", action: "plan", policy: "selected", layout: "batch", public: map[string]string{}, secrets: map[string]string{}, flags: command.Flags()}
		o.refresh, _ = command.Flags().GetBool("refresh-inventory")
		err = prepareCommandOptions(command, &o)
		if err != nil {
			t.Fatal(err)
		}
		overrides, err := config.FromEnvironment(o.public)
		if err != nil {
			t.Fatal(err)
		}
		p, err := config.Load(context.Background(), config.Options{Name: "topology", CWD: root, Home: root, Directories: []string{}, Environment: map[string]string{"NC_TOPOLOGY_CACHE_MODE": "only"}, Defaults: config.Defaults("topology"), Overrides: overrides, AllowMissing: true})
		if err != nil {
			t.Fatal(err)
		}
		if got := bootstrap.InventoryMode(p, o.mode, o.refresh, o.flags.Changed("cache-only") || o.flags.Changed("cache-mode")); string(got) != tc.want {
			t.Fatalf("%v: got %s, want %s", tc.args, got, tc.want)
		}
	}
}

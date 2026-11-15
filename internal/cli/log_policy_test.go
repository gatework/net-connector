package cli

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/netdisco"
)

func TestCLILogPolicyExecution(t *testing.T) {
	for _, tc := range []struct {
		name, layout, level   string
		custom, enabled, tftp bool
	}{
		{"flat_tftp_default", "flat", "info", false, true, true},
		{"batch_tftp_default", "batch", "info", false, true, true},
		{"custom_tftp", "batch", "debug", true, true, true},
		{"root_default", "flat", "", false, false, false},
		{"batch_default", "batch", "", false, false, false},
		{"explicit_info", "flat", "info", true, true, false},
		{"explicit_debug", "batch", "debug", true, true, false},
		{"explicit_warn", "flat", "warn", true, true, false},
		{"explicit_error", "flat", "error", true, true, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, _, errout := fixtureRuntime(t)
			r.Args = []string{"backup", "run", "--layout", tc.layout, "--all", "--non-interactive", "--json", "--username", "user", "--password", "PRIVATE_PASSWORD"}
			if tc.tftp {
				r.Args[1] = "tftp"
				r.Args = append(r.Args, "--tftp-server", "192.0.2.9", "--success-policy", "selected")
			}
			logs := filepath.Join(r.CWD, "custom-logs")
			if tc.custom {
				r.Environment["NC_LOG_DIRECTORY"] = logs
			}
			if tc.level != "" {
				r.Environment["NC_LOG_LEVEL"] = tc.level
			}
			r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) {
				return []inventory.Device{{IP: "192.0.2.1", Vendor: "cisco", OS: "nxos"}}, nil
			})
			r.DeviceFactory = func(_ connector.Driver, c connector.ConnectionConfig) (*connector.Device, error) {
				p := connector.StaticDriver{Grammar: connector.Terminal{Name: "cisco_nxos", LoginPrompt: testPattern(`sw#$`), CommandPrompt: testPattern(`sw#$`), ConfigCommands: []string{"show config"}}, Prepare: func(ctx context.Context, c connector.Command, e connector.Executor) (connector.Command, bool, error) {
					_, err := e.Execute(ctx, connector.Command{Text: "show visible"})
					return c, false, err
				}}
				return connector.New(p, c, connector.WithTransportFactory(func(context.Context, connector.ConnectionConfig) (io.ReadWriteCloser, error) {
					a, b := net.Pipe()
					go func() {
						defer b.Close()
						_, _ = io.WriteString(b, "sw#")
						scanner := bufio.NewScanner(b)
						for scanner.Scan() {
							text := "PRIVATE_CONFIG"
							if tc.tftp {
								text = "123 bytes copied"
							}
							if scanner.Text() == "show visible" {
								text = "PUBLIC_RESPONSE PRIVATE_PASSWORD"
							}
							_, _ = io.WriteString(b, text+"\r\nsw#")
						}
					}()
					return a, nil
				}))
			}
			if code := r.Run(t.Context()); code != 0 {
				t.Fatal(code, errout.String())
			}
			reportPath := filepath.Join(r.CWD, "backups", "report.json")
			if tc.layout != "flat" {
				entries, err := os.ReadDir(filepath.Dir(reportPath))
				if err != nil || len(entries) != 1 {
					t.Fatal(entries, err)
				}
				reportPath = filepath.Join(r.CWD, "backups", entries[0].Name(), "report.json")
			}
			data, err := os.ReadFile(reportPath)
			if err != nil {
				t.Fatal(err)
			}
			var report map[string]any
			if err = json.Unmarshal(data, &report); err != nil {
				t.Fatal(err)
			}
			row := report["devices"].([]any)[0].(map[string]any)
			path, _ := row["session_log"].(string)
			if !tc.enabled {
				if path != "" {
					t.Errorf("default created session log %s", path)
				}
				if _, err := os.Stat(filepath.Join(filepath.Dir(reportPath), "logs")); !os.IsNotExist(err) {
					t.Errorf("unexpected default logs directory: %v", err)
				}
				return
			}
			if !tc.custom {
				logs = filepath.Join(filepath.Dir(reportPath), "logs")
			}
			want := filepath.Join(logs, "192.0.2.1.log")
			if path != want {
				t.Errorf("report log=%s want=%s", path, want)
			}
			b, err := os.ReadFile(want)
			if err != nil {
				t.Fatal(err)
			}
			log := string(b)
			if strings.Contains(log, "PRIVATE_") {
				t.Fatal("secret in log", log)
			}
			if (tc.level == "debug") != strings.Contains(log, "PUBLIC_RESPONSE") {
				t.Errorf("level %s transcript: %s", tc.level, log)
			}
			if tc.level == "info" || tc.level == "debug" {
				for _, event := range []string{"event=connect", "event=login_complete", "event=command_start", "event=command_complete", "event=operation_complete"} {
					if !strings.Contains(log, event) {
						t.Errorf("missing %s: %s", event, log)
					}
				}
				if !regexp.MustCompile(`(?m)^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} [+-]\d{2}:\d{2}\] INFO \[host=`).MatchString(log) {
					t.Error("missing timestamp/severity/event format", log)
				}
			} else if len(log) != 0 {
				t.Error("success events below threshold", log)
			}
		})
	}
}
func TestInvalidLogLevelIsOffline(t *testing.T) {
	r, _, _ := fixtureRuntime(t)
	r.Args = []string{"backup", "run", "--all", "--non-interactive"}
	r.Environment["NC_LOG_LEVEL"] = "trace"
	calls := 0
	r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) { calls++; return nil, nil })
	if code := r.Run(t.Context()); code != 2 || calls != 0 {
		t.Fatalf("code=%d inventory=%d", code, calls)
	}
}

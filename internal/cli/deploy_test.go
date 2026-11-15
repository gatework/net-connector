package cli

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/internal/batchreport"
	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/netdisco"
)

func writeScript(t *testing.T, dir, name, body string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestDeployInvalidScriptFailsBeforeInventoryOrDevice(t *testing.T) {
	for name, args := range map[string][]string{
		"control char":     {"--script", "bad.txt"},
		"invalid utf8":     {"--script", "binary.txt"},
		"missing script":   {},
		"unknown platform": {"--script-for", "acme=good.txt"},
		"bad assignment":   {"--script-for", "cisco_ios"},
		"negative limit":   {"--script", "good.txt", "--stop-after-failures", "-1"},
	} {
		t.Run(name, func(t *testing.T) {
			r, _, errout := fixtureRuntime(t)
			writeScript(t, r.CWD, "good.txt", "vlan 10\n")
			writeScript(t, r.CWD, "bad.txt", "vlan 10\nname \x01\n")
			writeScript(t, r.CWD, "binary.txt", "vlan 10\nname \xff\n")
			r.Args = append([]string{"deploy", "run", "--non-interactive"}, args...)
			r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) {
				t.Fatal("inventory read before script validation")
				return nil, nil
			})
			r.DeviceFactory = func(connector.Driver, connector.ConnectionConfig) (*connector.Device, error) {
				t.Fatal("device constructed before script validation")
				return nil, nil
			}
			if code := r.Run(t.Context()); code != 2 {
				t.Fatalf("code=%d stderr=%s", code, errout.String())
			}
			if (name == "control char" || name == "invalid utf8") && !strings.Contains(errout.String(), "第 2 行") {
				t.Fatalf("line not reported: %s", errout.String())
			}
		})
	}
}

func TestDeployPlanJSONNeverConstructsDevice(t *testing.T) {
	r, out, errout := fixtureRuntime(t)
	writeScript(t, r.CWD, "ios.txt", "# comment\nntp server 192.0.2.50\n")
	r.Args = []string{"deploy", "plan", "--script-for", "cisco_ios=ios.txt", "--json", "--quiet"}
	r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) {
		return []inventory.Device{{IP: "192.0.2.1", Vendor: "cisco", OS: "ios", Name: "core"}, {IP: "192.0.2.2", Vendor: "huawei"}}, nil
	})
	r.DeviceFactory = func(connector.Driver, connector.ConnectionConfig) (*connector.Device, error) {
		t.Fatal("plan constructed a device")
		return nil, nil
	}
	if code := r.Run(t.Context()); code != 0 {
		t.Fatalf("code=%d stderr=%s", code, errout.String())
	}
	var got batchreport.Report
	if err := json.Unmarshal(out.Bytes(), &got); err != nil {
		t.Fatal(err, out.String())
	}
	if got.Status != "planned" || got.Devices[0].Target.Script != "ios.txt" || got.Devices[0].Target.Commands != 1 || got.Counts["missing_script"] != 1 {
		t.Fatalf("unexpected plan: %+v", got)
	}
}

func TestDeployRunEndToEndWritesReport(t *testing.T) {
	r, out, errout := fixtureRuntime(t)
	writeScript(t, r.CWD, "ntp.txt", "ntp server 192.0.2.50\n")
	r.Args = []string{"deploy", "run", "--script", "ntp.txt", "--no-snapshot", "--json", "--quiet", "--non-interactive", "--username", "operator", "--password", "private-secret"}
	r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) {
		return []inventory.Device{{IP: "192.0.2.1", Vendor: "cisco", OS: "ios", Name: "core"}}, nil
	})
	var received atomic.Value
	r.DeviceFactory = func(_ connector.Driver, c connector.ConnectionConfig) (*connector.Device, error) {
		return connector.New(connector.StaticDriver{Grammar: connector.Terminal{Name: "cisco_ios", LoginPrompt: testPattern(`sw#\s*\z`), CommandPrompt: testPattern(`sw#\s*\z`)}}, c, connector.WithTransportFactory(func(context.Context, connector.ConnectionConfig) (io.ReadWriteCloser, error) {
			a, b := net.Pipe()
			go func() {
				defer b.Close()
				_, _ = io.WriteString(b, "sw#")
				line, err := bufio.NewReader(b).ReadString('\n')
				if err != nil {
					return
				}
				received.Store(strings.TrimSpace(line))
				_, _ = io.WriteString(b, line+"sw#")
				_, _ = io.Copy(io.Discard, b)
			}()
			return a, nil
		}))
	}
	if code := r.Run(t.Context()); code != 0 {
		t.Fatalf("code=%d stderr=%s", code, errout.String())
	}
	if received.Load() != "ntp server 192.0.2.50" {
		t.Fatalf("device received %v", received.Load())
	}
	if strings.Contains(out.String(), "private-secret") || strings.Contains(errout.String(), "private-secret") {
		t.Fatal("secret in output")
	}
	var report batchreport.Report
	if err := json.Unmarshal(out.Bytes(), &report); err != nil {
		t.Fatal(err, out.String())
	}
	if !report.Success || report.Operation != "deploy" || report.Counts[batchreport.StatusSucceeded] != 1 || report.Devices[0].Outcome != "deployed" || !strings.HasPrefix(report.Directory, filepath.Join(r.CWD, "deploys")) {
		t.Fatalf("unexpected report: %+v", report)
	}
	if _, err := os.Stat(filepath.Join(report.Directory, "report.json")); err != nil {
		t.Fatal(err)
	}
}

func TestExecRefusesWriteCommandsWithoutConnecting(t *testing.T) {
	r, out, errout := fixtureRuntime(t)
	r.Args = []string{"exec", "run", "--command", "configure terminal", "--json", "--quiet", "--non-interactive", "--username", "operator", "--password", "secret"}
	r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) {
		return []inventory.Device{{IP: "192.0.2.1", Vendor: "cisco", OS: "ios"}}, nil
	})
	r.DeviceFactory = func(connector.Driver, connector.ConnectionConfig) (*connector.Device, error) {
		t.Fatal("exec connected for a write command")
		return nil, nil
	}
	if code := r.Run(t.Context()); code != 1 {
		t.Fatalf("code=%d stderr=%s", code, errout.String())
	}
	var report batchreport.Report
	if err := json.Unmarshal(out.Bytes(), &report); err != nil || report.Devices[0].Status != "not_read_only" {
		t.Fatal(err, out.String())
	}
}

func TestExecRequiresCommands(t *testing.T) {
	r, _, errout := fixtureRuntime(t)
	r.Args = []string{"exec", "plan"}
	r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) {
		t.Fatal("inventory read without commands")
		return nil, nil
	})
	if code := r.Run(t.Context()); code != 2 || !strings.Contains(errout.String(), "--command") {
		t.Fatalf("code=%d stderr=%s", code, errout.String())
	}
}

package cli

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/internal/batchreport"
	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/netdisco"
)

func fixtureRuntime(t *testing.T) (Runtime, *bytes.Buffer, *bytes.Buffer) {
	t.Helper()
	root := t.TempDir()
	var out, errout bytes.Buffer
	return Runtime{CWD: root, Home: root, Directories: []string{}, Environment: map[string]string{}, Input: panicReader{}, Output: &out, Error: &errout}, &out, &errout
}
func TestInvalidNumericAndModeFlagsAreOffline(t *testing.T) {
	for _, args := range [][]string{{"--sample", "0"}, {"--parallel", "0"}, {"--limit", "0"}, {"--apply", "--plan"}, {"--ask-password", "--stdin-credentials"}, {"--host", "192.0.2.0/24"}} {
		r, _, errout := fixtureRuntime(t)
		r.Args = append([]string{"topology", "plan"}, args...)
		if code := r.Run(t.Context()); code != 2 {
			t.Fatal(args, code, errout.String())
		}
	}
}
func TestInventoryOnlyNeverConstructsDevice(t *testing.T) {
	r, out, errout := fixtureRuntime(t)
	r.Args = []string{"inventory", "list"}
	r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) {
		return []inventory.Device{{IP: "192.0.2.1", Vendor: "cisco", OS: "ios"}}, nil
	})
	r.DeviceFactory = func(connector.Driver, connector.ConnectionConfig) (*connector.Device, error) {
		t.Fatal("constructed device")
		return nil, nil
	}
	if code := r.Run(t.Context()); code != 0 || !strings.Contains(out.String(), "192.0.2.1") {
		t.Fatal(code, out.String(), errout.String())
	}
}
func TestStdinCredentialsOverrideVendorAndRequireRUN(t *testing.T) {
	for _, run := range []string{"STOP", "RUN"} {
		t.Run(run, func(t *testing.T) {
			r, _, errout := fixtureRuntime(t)
			r.Args = []string{"backup", "run", "--stdin-credentials", "--all"}
			r.Environment = map[string]string{"NC_CISCO_IOS_USERNAME": "old", "NC_CISCO_IOS_PASSWORD": "old"}
			r.Input = strings.NewReader(`{"netdisco_username":"nd","netdisco_password":"nd-secret","device_username":"new","device_password":"new-secret"}` + "\n" + run + "\n")
			r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) {
				return []inventory.Device{{IP: "192.0.2.1", Vendor: "cisco", OS: "ios"}}, nil
			})
			calls := 0
			r.DeviceFactory = func(_ connector.Driver, c connector.ConnectionConfig) (*connector.Device, error) {
				calls++
				if c.Username != "new" || c.Password != "new-secret" {
					t.Fatal("wrong credentials")
				}
				return nil, fmt.Errorf("expected fixture error")
			}
			code := r.Run(t.Context())
			if run == "STOP" && calls != 0 || run == "RUN" && (calls != 1 || code != 1) {
				t.Fatal(code, calls, errout.String())
			}
		})
	}
}
func TestTFTPVerifiedLocalArchiveEndToEnd(t *testing.T) {
	r, out, errout := fixtureRuntime(t)
	root := t.TempDir()
	root, _ = filepath.EvalSymlinks(root)
	r.Args = []string{"backup", "tftp", "--json", "--tftp-server", "192.0.2.9", "--tftp-root", root, "--success-policy", "verified", "--username", "user", "--password", "private-secret"}
	r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) {
		return []inventory.Device{{IP: "192.0.2.1", Name: "edge", Vendor: "cisco", OS: "nxos"}}, nil
	})
	var uploads atomic.Int32
	peers := make(chan struct{})
	r.DeviceFactory = func(_ connector.Driver, c connector.ConnectionConfig) (*connector.Device, error) {
		return connector.New(connector.StaticDriver{Grammar: connector.Terminal{Name: "cisco_nxos", LoginPrompt: testPattern(`sw#\s*$`), CommandPrompt: testPattern(`sw#\s*$`)}}, c, connector.WithTransportFactory(func(context.Context, connector.ConnectionConfig) (io.ReadWriteCloser, error) {
			a, b := net.Pipe()
			go func() {
				defer close(peers)
				defer b.Close()
				io.WriteString(b, "sw#")
				reader := bufio.NewReader(b)
				line, e := reader.ReadString('\n')
				if e != nil {
					return
				}
				fields := strings.Fields(line)
				if len(fields) != 5 {
					t.Errorf("command %q", line)
					return
				}
				name := strings.TrimPrefix(fields[2], "tftp://192.0.2.9/")
				if filepath.Base(name) != name {
					t.Errorf("invalid name")
					return
				}
				uploads.Add(1)
				if e := os.WriteFile(filepath.Join(root, name), []byte("configuration bytes"), 0600); e != nil {
					t.Error(e)
				}
				io.WriteString(b, line+"123 bytes copied\r\nsw#")
				io.Copy(io.Discard, b)
			}()
			return a, nil
		}))
	}
	if code := r.Run(t.Context()); code != 0 {
		t.Fatal(code, out.String(), errout.String())
	}
	select {
	case <-peers:
	case <-time.After(time.Second):
		t.Fatal("peer leak")
	}
	var report batchreport.Report
	if e := json.Unmarshal(out.Bytes(), &report); e != nil {
		t.Fatal(e)
	}
	reportBytes, e := os.ReadFile(filepath.Join(report.Directory, "report.json"))
	if e != nil {
		t.Fatal(e)
	}
	if e = json.Unmarshal(reportBytes, &report); e != nil {
		t.Fatal(e)
	}
	row := report.Devices[0]
	if !row.Verified || row.Artifacts.Transfer.Verification != "server_verified" || uploads.Load() != 1 {
		t.Fatal(row)
	}
	for key, path := range map[string]string{"local_file": row.Artifacts.Archive.Local.Path, "server_archive_file": row.Artifacts.Archive.Server.ArchivePath, "session_log": row.SessionLog} {
		b, e := os.ReadFile(path)
		if e != nil || bytes.Contains(b, []byte("private-secret")) {
			t.Fatal(key, e)
		}
	}
	if _, e := os.Lstat(filepath.Join(root, row.Artifacts.Transfer.RemotePath)); !os.IsNotExist(e) {
		t.Fatal("staging not cleaned", e)
	}
}

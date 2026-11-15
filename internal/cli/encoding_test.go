package cli

import (
	"context"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/netdisco"
)

func TestBackupAutomaticallyDecodesDeviceOutput(t *testing.T) {
	for _, tc := range []struct{ name, wire, want string }{
		{"ascii", "uplink", "uplink"},
		{"utf8", "中文", "中文"},
		{"native-truncated", "中文\xe2", "中文\xe2"},
		{"gbk", "\xd6\xd0\xce\xc4", "中文"},
		{"gb18030", "\x95\x34\xb2\x35", "𠮷"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, out, errout := fixtureRuntime(t)
			dir := filepath.Join(r.CWD, "backups")
			r.Args = []string{"backup", "run", "--layout", "flat", "--all", "--directory", dir, "--username", "user", "--password", "secret"}
			r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) {
				return []inventory.Device{{IP: "192.0.2.1", Vendor: "h3c"}}, nil
			})
			done := make(chan error, 1)
			r.DeviceFactory = func(p connector.Driver, c connector.ConnectionConfig) (*connector.Device, error) {
				c.LoginTimeout, c.CommandTimeout = time.Second, time.Second
				return connector.New(p, c, connector.WithTransportFactory(func(context.Context, connector.ConnectionConfig) (io.ReadWriteCloser, error) {
					a, b := net.Pipe()
					go func() {
						defer b.Close()
						if _, err := io.WriteString(b, "<core>"); err != nil {
							done <- err
							return
						}
						command := make([]byte, len("dis cur\n"))
						if _, err := io.ReadFull(b, command); err != nil {
							done <- err
							return
						}
						if string(command) != "dis cur\n" {
							done <- errors.New("unexpected command")
							return
						}
						// Split every multibyte character across transport reads.
						for _, ch := range []byte("dis cur\r\n description " + tc.wire + "\r\n<core>") {
							if _, err := b.Write([]byte{ch}); err != nil {
								done <- err
								return
							}
						}
						_, err := io.Copy(io.Discard, b)
						done <- err
					}()
					return a, nil
				}))
			}
			if code := r.Run(t.Context()); code != 0 {
				t.Fatalf("exit %d: %s %s", code, out.String(), errout.String())
			}
			select {
			case err := <-done:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(time.Second):
				t.Fatal("fixture did not exit")
			}
			files, err := filepath.Glob(filepath.Join(dir, "unnamed-192.0.2.1.txt"))
			if err != nil || len(files) != 1 {
				t.Fatalf("backup files %v, %v", files, err)
			}
			got, err := os.ReadFile(files[0])
			if err != nil || string(got) != "dis cur\n description "+tc.want+"\n<core>" {
				t.Fatalf("backup = %q, %v", got, err)
			}
		})
	}
}

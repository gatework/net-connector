package transfer_test

import (
	"bufio"
	"context"
	"errors"
	"io"
	"net"
	"testing"
	"time"

	"github.com/gatework/net-connector/transfer"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/vendors"
)

func tftpPolicyForTest(tb testing.TB, vendor string) transfer.TFTPPolicy {
	tb.Helper()
	platform, err := vendors.NewBuiltinRegistry().Lookup(vendor)
	if err != nil {
		tb.Fatal(err)
	}
	policy, ok := platform.(transfer.TFTPPolicy)
	if !ok {
		tb.Fatalf("platform %q has no TFTP policy", vendor)
	}
	return policy
}

func transferDevice(t *testing.T, vendor string, dialogue [][2]string) *connector.Device {
	t.Helper()
	done := make(chan struct{})
	d, e := connector.New(connector.StaticDriver{Grammar: connector.Terminal{Name: vendor, LoginPrompt: testPattern(`sw#\s*$`), CommandPrompt: testPattern(`sw#\s*$`)}}, connector.ConnectionConfig{Host: "192.0.2.1", CommandTimeout: time.Second}, connector.WithTransportFactory(func(context.Context, connector.ConnectionConfig) (io.ReadWriteCloser, error) {
		a, b := net.Pipe()
		go func() {
			defer close(done)
			defer b.Close()
			io.WriteString(b, "sw#")
			r := bufio.NewReader(b)
			for _, step := range dialogue {
				line, e := r.ReadString('\n')
				if e != nil {
					return
				}
				if line != step[0]+"\n" {
					t.Errorf("command got %q want %q", line, step[0])
				}
				io.WriteString(b, step[1])
			}
			io.Copy(io.Discard, b)
		}()
		return a, nil
	}))
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() {
		d.Close()
		select {
		case <-done:
		case <-time.After(time.Second):
			t.Error("peer did not exit")
		}
	})
	return d
}
func TestTFTPPlatforms(t *testing.T) {
	for _, test := range []struct{ vendor, command, success string }{{"cisco_nxos", "copy running-config tftp://192.0.2.9/backup.cfg vrf management", "123 bytes copied"}, {"fortinet", "execute backup full-config tftp backup.cfg 192.0.2.9", "Send config file to tftp server OK."}, {"centec", "copy running-config tftp://192.0.2.9/backup.cfg", "Sent 123 bytes in 1.2 seconds"}, {"hillstone", "export configuration startup to tftp server 192.0.2.9 vrouter mgt-vr backup.cfg", "Export ok, target file name backup.cfg"}} {
		t.Run(test.vendor, func(t *testing.T) {
			d := transferDevice(t, test.vendor, [][2]string{{test.command, test.command + "\r\n" + test.success + "\r\nsw#"}})
			result, e := transfer.TFTP(t.Context(), vendors.NewBuiltinRegistry(), d, transfer.TFTPOptions{Server: "192.0.2.9", Path: "backup.cfg"})
			if e != nil || !result.Receipt.Reported() || result.Receipt.Verification != transfer.VerificationDeviceReported || len(result.Steps) != 1 {
				t.Fatal(result, e)
			}
		})
	}
}
func TestTFTPFailureOverridesPositiveAndFilenameIsNotFailure(t *testing.T) {
	for _, body := range []string{"123 bytes copied\r\nTransfer failed.", "123 bytes copied"} {
		d := transferDevice(t, "cisco_nxos", [][2]string{{"copy running-config tftp://192.0.2.9/failed.cfg vrf management", "copy running-config tftp://192.0.2.9/failed.cfg vrf management\r\n" + body + "\r\nsw#"}})
		r, e := transfer.TFTP(t.Context(), vendors.NewBuiltinRegistry(), d, transfer.TFTPOptions{Server: "192.0.2.9", Path: "failed.cfg"})
		if (e == nil) != (body == "123 bytes copied") || r.Receipt.Reported() != (e == nil) {
			t.Fatal(r, e)
		}
	}
}
func TestH3CSourceDiscoveryAndIOSDialogue(t *testing.T) {
	d := transferDevice(t, "h3c", [][2]string{{"display startup", "display startup\r\nNext main startup saved-configuration file: flash:/startup.cfg\r\nsw#"}, {"tftp 192.0.2.9 put flash:/startup.cfg backup.cfg source ip 192.0.2.1", "File transfer completed successfully.\r\nsw#"}})
	r, e := transfer.TFTP(t.Context(), vendors.NewBuiltinRegistry(), d, transfer.TFTPOptions{Server: "192.0.2.9", Path: "backup.cfg", SourceInterface: "management"})
	if e != nil || r.Receipt.ConfigurationKind != "startup" || len(r.Steps) != 2 {
		t.Fatal(r, e)
	}
	d = transferDevice(t, "cisco_ios", [][2]string{{"copy running-config tftp:", "Address or name of remote host []? "}, {"192.0.2.9", "Destination filename [router-confg]? "}, {"backup.cfg", "[OK - 123 bytes]\r\nsw#"}})
	r, e = transfer.TFTP(t.Context(), vendors.NewBuiltinRegistry(), d, transfer.TFTPOptions{Server: "192.0.2.9", Path: "backup.cfg"})
	if e != nil || !r.Receipt.Reported() {
		t.Fatal(r, e)
	}
}

func TestTFTPFileCompletion(t *testing.T) {
	t.Parallel()
	for _, vendor := range []string{"h3c", "h3c_wireless", "huawei"} {
		for _, test := range []struct {
			name, body string
			reported   bool
		}{
			{"message", "File transfer completed successfully.", true},
			{"bytes", "TFTP: 123 bytes sent in 0.25 second(s)", true},
			{"progress", "99 123k 0 0 99 123k 0 0 0\r\n100 123k 0 0 100 123k 0 0 0", true},
			{"incomplete_progress", "100 123k 0 0 100 12k 0 0 0", false},
		} {
			t.Run(vendor+"/"+test.name, func(t *testing.T) {
				t.Parallel()
				const command = "tftp 192.0.2.9 put flash:/startup.cfg backup.cfg"
				d := transferDevice(t, vendor, [][2]string{{command, command + "\r\n" + test.body + "\r\nsw#"}})
				result, err := transfer.TFTP(t.Context(), vendors.NewBuiltinRegistry(), d, transfer.TFTPOptions{Server: "192.0.2.9", Path: "backup.cfg", SourceFile: "flash:/startup.cfg"})
				if result.Receipt.Reported() != test.reported || len(result.Steps) != 1 {
					t.Fatalf("transfer result: %v, error: %v", result, err)
				}
				if test.reported {
					if err != nil || result.Receipt.ConfigurationKind != "saved_file" || result.Receipt.Path != "backup.cfg" {
						t.Fatalf("transfer result: %v, error: %v", result, err)
					}
				} else if !errors.Is(err, transfer.ErrUnconfirmed) {
					t.Fatalf("completion error = %v, want unconfirmed", err)
				}
			})
		}
	}
}

func TestTFTPFailureRetainsExecutionCause(t *testing.T) {
	cause := errors.New("after command failed")
	profile := connector.StaticDriver{Grammar: connector.Terminal{Name: "cisco_nxos", LoginPrompt: testPattern(`sw#$`), CommandPrompt: testPattern(`sw#$`)}, AfterCommand: func(context.Context, connector.Command, connector.StepResult, connector.Executor) error { return cause }}
	d, e := connector.New(profile, connector.ConnectionConfig{Host: "192.0.2.1", CommandTimeout: time.Second}, connector.WithTransportFactory(func(context.Context, connector.ConnectionConfig) (io.ReadWriteCloser, error) {
		a, b := net.Pipe()
		go func() {
			defer b.Close()
			io.WriteString(b, "sw#")
			bufio.NewReader(b).ReadString('\n')
			io.WriteString(b, "Transfer failed.\r\nsw#")
			io.Copy(io.Discard, b)
		}()
		return a, nil
	}))
	if e != nil {
		t.Fatal(e)
	}
	defer d.Close()
	_, e = transfer.TFTP(t.Context(), vendors.NewBuiltinRegistry(), d, transfer.TFTPOptions{Server: "192.0.2.9", Path: "backup.cfg"})
	var transferErr *transfer.Error
	if !errors.As(e, &transferErr) || transferErr.Code != "transfer_failed" || !errors.Is(e, connector.ErrDevice) || !errors.Is(e, cause) {
		t.Fatalf("execution cause lost: %v", e)
	}
}

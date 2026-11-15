package transfer_test

import (
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/gatework/net-connector/transfer"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/vendors"
)

func TestRemoteExactCompletionAndFailurePriority(t *testing.T) {
	for _, tc := range []struct {
		body string
		ok   bool
	}{
		{"Wrote 4 lines of output to 'scp://backup@192.0.2.9/site/config.conf'", true},
		{"Wrote 4 lines of output to 'scp://backup@192.0.2.9/other.conf'", false},
		{"Wrote 0 lines of output to 'scp://backup@192.0.2.9/site/config.conf'", false},
		{"Wrote 4 lines of output to 'scp://backup@192.0.2.9/site/config.conf'\r\nerror: write failed", false},
	} {
		command := "show configuration | save scp://backup@192.0.2.9/site/config.conf"
		d := transferDevice(t, "juniper", [][2]string{{command, "Password: "}, {"secret", tc.body + "\r\nsw#"}})
		r, e := transfer.RemoteBackup(t.Context(), vendors.NewBuiltinRegistry(), d, transfer.RemoteOptions{Server: "192.0.2.9", Path: "site/config.conf", Username: "backup", Password: "secret"})
		if (e == nil) != tc.ok || r.Receipt.Reported() != tc.ok {
			t.Fatal(r, e)
		}
		if strings.Contains(fmt.Sprintf("%#v %v", r, e), "secret") {
			t.Fatal("secret disclosed")
		}
	}
}

func TestRemoteBackupRequiresPlatformCapability(t *testing.T) {
	declaration, err := vendors.NewBuiltinRegistry().Lookup("h3c")
	if err != nil {
		t.Fatal(err)
	}
	d, err := connector.New(declaration, connector.ConnectionConfig{Host: "192.0.2.1"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = transfer.RemoteBackup(t.Context(), vendors.NewBuiltinRegistry(), d, transfer.RemoteOptions{Server: "192.0.2.9", Path: "config.cfg", Username: "backup"}); !errors.Is(err, transfer.ErrUnsupported) {
		t.Fatalf("remote backup error = %v, want unsupported", err)
	}
}
func TestRemoteRejectsBeforeDeviceIO(t *testing.T) {
	for _, o := range []transfer.RemoteOptions{{Server: "bad;host", Path: "config", Username: "u"}, {Server: "host", Path: "../config", Username: "u"}, {Server: "host", Path: "config", Username: "u", Password: "x\ny"}, {Server: "host", Path: "config", Username: "u", Protocol: "sftp"}} {
		if e := transfer.ValidateRemote(o); !errors.Is(e, transfer.ErrInvalid) {
			t.Fatal(e)
		}
	}
}

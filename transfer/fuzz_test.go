package transfer_test

import (
	"testing"

	"github.com/gatework/net-connector/transfer"

	"github.com/gatework/net-connector/vendors"
)

func FuzzTargetValidation(f *testing.F) {
	f.Add("server", "site/config.cfg", "flash:/startup.cfg")
	f.Add("x;echo", "../bad", "\x00")
	f.Fuzz(func(t *testing.T, server, path, source string) {
		if len(server)+len(path)+len(source) > 1<<16 {
			t.Skip()
		}
		_ = transfer.Validate(vendors.NewBuiltinRegistry(), "h3c", "192.0.2.1", transfer.TFTPOptions{Server: server, Path: path, SourceFile: source})
		_ = transfer.ValidateRemote(transfer.RemoteOptions{Server: server, Path: path, Username: "backup"})
	})
}

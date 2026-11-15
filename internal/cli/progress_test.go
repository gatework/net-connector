package cli

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/netdisco"
)

func TestBackupAnnouncesInventoryBeforeWaiting(t *testing.T) {
	r, out, diagnostic := fixtureRuntime(t)
	r.Args = []string{"backup", "run", "--json", "--"}
	r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) {
		if !strings.Contains(diagnostic.String(), "正在读取设备清单") {
			t.Error("inventory started with no stage announcement")
		}
		return nil, nil
	})
	if code := r.Run(t.Context()); code != 1 {
		t.Fatalf("exit=%d diagnostics=%s", code, diagnostic.String())
	}
	if !json.Valid(out.Bytes()) {
		t.Fatalf("stdout contaminated: %s", out.String())
	}
	if !strings.Contains(diagnostic.String(), "设备清单读取完成：0 台") {
		t.Fatal(diagnostic.String())
	}
}

func TestQuietSuppressesPreparationProgress(t *testing.T) {
	r, out, diagnostic := fixtureRuntime(t)
	r.Args = []string{"backup", "run", "--json", "--quiet"}
	r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) { return nil, nil })
	if code := r.Run(t.Context()); code != 1 {
		t.Fatalf("exit=%d diagnostics=%s", code, diagnostic.String())
	}
	if diagnostic.Len() != 0 {
		t.Fatalf("quiet progress: %s", diagnostic.String())
	}
	if !json.Valid(out.Bytes()) {
		t.Fatal(out.String())
	}
}

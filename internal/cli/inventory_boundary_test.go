package cli

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/netdisco"
)

func TestTopologyInventoryCannotOpenDeviceOrCreateBatch(t *testing.T) {
	r, out, diag := fixtureRuntime(t)
	root := filepath.Join(r.CWD, "reports")
	r.Args = []string{"inventory", "list", "--for", "topology", "--json"}
	r.Environment["NC_TOPOLOGY_MODE"] = "apply"
	r.Environment["NC_TOPOLOGY_DIRECTORY"] = root
	r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) {
		return []inventory.Device{{IP: "192.0.2.1", Name: "edge", Vendor: "h3c"}}, nil
	})
	r.DeviceFactory = func(connector.Driver, connector.ConnectionConfig) (*connector.Device, error) {
		panic("inventory constructed a device")
	}
	if code := r.Run(t.Context()); code != 0 {
		t.Fatalf("code=%d out=%s diagnostic=%s", code, out.String(), diag.String())
	}
	if _, e := os.Stat(root); !os.IsNotExist(e) {
		t.Fatalf("inventory created batch output: %v", e)
	}
}

func TestHumanInventoryShowsAnomaliesInTable(t *testing.T) {
	for _, purpose := range []string{"backup", "topology"} {
		r, out, diag := fixtureRuntime(t)
		r.Args = []string{"inventory", "list", "--for", purpose}
		r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) {
			return []inventory.Device{{IP: "192.0.2.1", Name: "normal", Vendor: "h3c"}, {IP: "192.0.2.2", Name: "unmapped", Vendor: "mystery"}}, nil
		})
		r.DeviceFactory = func(connector.Driver, connector.ConnectionConfig) (*connector.Device, error) {
			panic("inventory opened device")
		}
		if code := r.Run(t.Context()); code != 0 {
			t.Fatalf("%d %s", code, diag.String())
		}
		text := out.String()
		for _, want := range []string{"名称", "型号", "状态", "unmapped", "normal"} {
			if !strings.Contains(text, want) {
				t.Fatal(text)
			}
		}
		if strings.Index(text, "unmapped") > strings.Index(text, "normal") {
			t.Fatal(text)
		}
	}
}

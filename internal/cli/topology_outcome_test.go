package cli

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	goruntime "runtime"
	"testing"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/netdisco"
)

func TestTopologyGoexitRetainsDeviceIdentity(t *testing.T) {
	r, _, errout := fixtureRuntime(t)
	directory := t.TempDir()
	r.Args = []string{"topology", "discover", "--directory", directory, "--non-interactive"}
	r.Environment["NC_DEVICE_USERNAME"] = "fixture"
	r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) {
		return []inventory.Device{{IP: "192.0.2.7", Vendor: "cisco", OS: "ios"}}, nil
	})
	r.DeviceFactory = func(connector.Driver, connector.ConnectionConfig) (*connector.Device, error) {
		goruntime.Goexit()
		return nil, nil
	}
	if code := r.Run(t.Context()); code != 1 {
		t.Fatalf("code=%d error=%s", code, errout.String())
	}
	paths, err := filepath.Glob(filepath.Join(directory, "*", "report.json"))
	if err != nil || len(paths) != 1 {
		t.Fatal(paths, err, errout.String())
	}
	data, err := os.ReadFile(paths[0])
	if err != nil {
		t.Fatal(err)
	}
	var report struct {
		Devices []struct{ Host, Platform, Status string }
	}
	if err = json.Unmarshal(data, &report); err != nil {
		t.Fatal(err)
	}
	if len(report.Devices) != 1 || report.Devices[0].Host != "192.0.2.7" || report.Devices[0].Platform != "cisco_ios" || report.Devices[0].Status != "failed" {
		t.Fatal(string(data))
	}
}

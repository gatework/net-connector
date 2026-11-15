package cli

import (
	"context"
	"strings"
	"testing"

	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/netdisco"
)

func TestTopologyConfigCheckValidatesDescriptionFormat(t *testing.T) {
	r, out, diag := fixtureRuntime(t)
	r.Args = []string{"config", "check", "--for", "topology"}
	r.Environment["NC_TOPOLOGY_DESCRIPTION_FORMAT"] = "%{bogus}"
	r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) {
		t.Fatal("config check accessed inventory")
		return nil, nil
	})
	if code := r.Run(t.Context()); code != 2 {
		t.Fatalf("code=%d out=%s diagnostic=%s", code, out.String(), diag.String())
	}
}

func TestConfigCheckHumanByDefault(t *testing.T) {
	r, out, _ := fixtureRuntime(t)
	r.Args = []string{"config", "check"}
	if code := r.Run(t.Context()); code != 0 {
		t.Fatal(code)
	}
	if !strings.Contains(out.String(), "配置检查通过") || strings.HasPrefix(out.String(), "{") {
		t.Fatal(out.String())
	}
}

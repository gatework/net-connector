package cli

import (
	"context"
	"testing"

	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/netdisco"
)

func TestReplacePreflightBeforeInventoryAndCredentials(t *testing.T) {
	r, _, errout := fixtureRuntime(t)
	r.Args = []string{"backup", "run", "--all", "--non-interactive"}
	r.Environment["NC_HOST_KEY_POLICY"] = "replace"
	calls := 0
	r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) { calls++; return nil, nil })
	if code := r.Run(t.Context()); code != 2 || calls != 0 {
		t.Fatalf("code=%d inventory=%d error=%s", code, calls, errout.String())
	}
}

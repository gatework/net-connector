package driver

import (
	"testing"

	"github.com/gatework/net-connector/connector"
)

func TestBaseConfigPolicyPreservesVisibleConfiguration(t *testing.T) {
	plain := "dis cur\nsysname core\n<core>"
	got, err := (BaseConfigPolicy{}).Clean(connector.StepResult{}, plain, "<core>")
	if err != nil || got != plain {
		t.Fatalf("base: %q %v", got, err)
	}
}

package centec

import (
	"testing"

	"github.com/gatework/net-connector/connector"
)

func TestConfigurationCleaningRetainsCentecBanner(t *testing.T) {
	want := "hostname Switch\nbanner motd ^\nSwitch#\n^\n"
	got, err := (configPolicy{}).Clean(connector.StepResult{}, "show running-config\n"+want+"Switch#", "Switch#")
	if err != nil || got != want {
		t.Fatalf("centec: %q %v", got, err)
	}
}

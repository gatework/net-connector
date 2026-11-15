package cisco

import (
	"testing"

	"github.com/gatework/net-connector/connector"
)

func TestConfigurationCleaningRetainsCiscoHeaderAndVolatileLines(t *testing.T) {
	header := "show running-config\nBuilding configuration...\n\nCurrent configuration : 123 bytes\n!\n"
	volatile := "! Last configuration change at 12:00\n! NVRAM config last updated at 12:00\n"
	body := "hostname switch\nbanner motd @\n" + volatile + "show running-config\nswitch#\n@\nend\nswitch#"
	got, err := (configPolicy{}).Clean(connector.StepResult{}, header+volatile+body, "switch#")
	if err != nil || got != header+body {
		t.Fatalf("cisco: %q %v", got, err)
	}
}

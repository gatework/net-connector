package vendors

import (
	"reflect"
	"testing"

	"github.com/gatework/net-connector/topology"
)

func TestRadwareExposesOnlyItsSupportedTopologyBehaviors(t *testing.T) {
	radware, err := NewBuiltinRegistry().Lookup("radware")
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := radware.(topology.NeighborDiscovery); ok {
		t.Fatal("Radware exposes neighbor discovery although its profile only supports interface descriptions")
	}
	if _, ok := radware.(topology.DescriptionReader); !ok {
		t.Fatal("Radware does not expose its supported interface description reader")
	}
	if _, ok := radware.(topology.InterfaceIdentity); !ok {
		t.Fatal("Radware does not expose interface identity normalization for parsed descriptions")
	}
	if _, ok := radware.(topology.DescriptionWriter); ok {
		t.Fatal("Radware exposes interface description writing although it is read-only")
	}
}

func TestCiscoTopologyWriterBuildsVendorChangeCommands(t *testing.T) {
	cisco, err := NewBuiltinRegistry().Lookup("cisco_ios")
	if err != nil {
		t.Fatal(err)
	}
	writer, ok := cisco.(topology.DescriptionWriter)
	if !ok {
		t.Fatal("Cisco IOS does not expose its interface description writer")
	}
	got, err := writer.ChangeCommands("GigabitEthernet1/0/1", "To_SW_Gi1/0/1")
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"interface GigabitEthernet1/0/1", "description To_SW_Gi1/0/1"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("change commands = %q, want %q", got, want)
	}
	wantMode := topology.WriteMode{Enter: "configure terminal", Leave: "end", InterfaceExit: "exit"}
	if got := writer.WriteMode(); got != wantMode {
		t.Fatalf("write mode = %+v, want %+v", got, wantMode)
	}
}

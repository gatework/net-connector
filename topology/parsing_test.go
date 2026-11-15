package topology_test

import (
	"encoding/json"
	"errors"
	"os"
	"testing"

	"github.com/gatework/net-connector/topology"

	"github.com/gatework/net-connector/vendors"
)

func TestParseNeighborPlatformsAndPartialEvidence(t *testing.T) {
	samples := neighborFixtures(t)
	for vendor, output := range samples {
		t.Run(vendor, func(t *testing.T) {
			n, e := topology.ParseNeighbors(neighborPolicyFor(t, vendor), output)
			if e != nil || len(n) != 1 || n[0].NeighborName != "peer" {
				t.Fatalf("%#v %v", n, e)
			}
			if _, e = topology.ParseNeighbors(neighborPolicyFor(t, vendor), ""); !errors.Is(e, topology.ErrParse) {
				t.Fatalf("empty output: %v", e)
			}
		})
	}
	for _, tc := range []struct{ vendor, output string }{{"h3c", "Local Interface Chassis ID Port ID System Name\nGE1/1 peer\n"}, {"hillstone", samples["hillstone"] + "unknown row\n"}, {"cisco_ios", samples["cisco_ios"] + "Device ID: incomplete\n"}, {"palo_alto", "Local information:\nLocal interface: ethernet1/2\nNeighbor information:\nChassis ID: partial\n"}} {
		t.Run(tc.vendor+"_partial", func(t *testing.T) {
			if _, e := topology.ParseNeighbors(neighborPolicyFor(t, tc.vendor), tc.output); !errors.Is(e, topology.ErrParse) {
				t.Fatalf("%v", e)
			}
		})
	}
	t.Run("structured diagnostic", func(t *testing.T) {
		_, err := topology.ParseNeighbors(neighborPolicyFor(t, "cisco_ios"), "malformed output")
		var diagnostic *topology.Error
		if !errors.As(err, &diagnostic) || diagnostic.Code != "unrecognized_output" || diagnostic.Phase != "parse" || !errors.Is(err, topology.ErrParse) {
			t.Fatalf("parse diagnostic = %#v, %v", diagnostic, err)
		}
	})
}
func TestParseDescriptionPlatforms(t *testing.T) {
	for vendor, config := range map[string]string{
		"h3c": "interface GigabitEthernet1/1\n description uplink\n#\n", "h3c_wireless": "interface GigabitEthernet1/1\n description uplink\n#\n",
		"huawei": "interface GigabitEthernet 1/1\n description uplink\n#\n", "cisco_ios": "interface GigabitEthernet1/1\n description uplink\n!\nend\n", "cisco_nxos": "interface GigabitEthernet1/1\n description uplink\n!\nend\n",
		"hillstone": "interface GigabitEthernet1/1\n description uplink\nexit\n", "fortinet": "config system interface\n    edit port1\n        set alias ignored\n        set description \"uplink\"\n    next\nend\n", "juniper": "set interfaces ge-0/0/0 description \"uplink\"\nset interfaces ge-0/0/0 unit 0 description customer\n", "palo_alto": "set network interface ethernet ethernet1/1 comment \"uplink\"\n", "radware": "/cfg/port 1/name \"uplink\"\n",
	} {
		t.Run(vendor, func(t *testing.T) {
			d, e := topology.ParseDescriptions(descriptionPolicyFor(t, vendor), config)
			if e != nil {
				t.Fatal(e)
			}
			found := false
			for _, v := range d {
				found = found || v == "uplink"
			}
			if !found {
				t.Fatalf("%#v", d)
			}
			if vendor == "juniper" && d["ge-0/0/0.0"] != "customer" {
				t.Fatal(d)
			}
		})
	}
}
func TestMalformedDescriptionEvidenceFailsClosed(t *testing.T) {
	cases := []struct{ vendor, config string }{{"cisco_ios", "interface malformed extra\n description partial\n!\n"}, {"huawei", "interface GE1/1 extra fields\n#\n"}, {"fortinet", "config system interface\n    edit port1\n        set description partial\nend\n"}, {"fortinet", "config system interface\nend\nconfig system interface\nend\n"}, {"fortinet", "config global\n    config system interface\n    end\nend\n"}, {"juniper", "set interfaces ge-0/0/0 description\n"}, {"palo_alto", "set network interface ethernet ethernet1/1 comment \"private-truncated\n"}, {"radware", "/cfg/port 1/name \"private-truncated\n"}, {"cisco_ios", "interface Gi1/1\n description x\n!\ninterface Gi1/1\n description y\n!\n"}}
	for _, tc := range cases {
		t.Run(tc.vendor+tc.config[:3], func(t *testing.T) {
			if _, e := topology.ParseDescriptions(descriptionPolicyFor(t, tc.vendor), tc.config); !errors.Is(e, topology.ErrParse) {
				t.Fatalf("%v", e)
			}
		})
	}
}

func TestConflictingDescriptionRetainsSpecificDiagnostic(t *testing.T) {
	config := "interface Gi1/1\n description x\n!\ninterface Gi1/1\n description y\n!\n"
	_, err := topology.ParseDescriptions(descriptionPolicyFor(t, "cisco_ios"), config)
	var diagnostic *topology.Error
	if !errors.As(err, &diagnostic) || diagnostic.Code != "ambiguous_description" || diagnostic.Phase != "parse" || !errors.Is(err, topology.ErrParse) {
		t.Fatalf("conflicting description diagnostic = %#v, %v", diagnostic, err)
	}
}
func TestEmptyNeighborTablesRequirePositiveEvidence(t *testing.T) {
	for vendor, body := range map[string]string{"h3c": "Local Interface Chassis ID Port ID System Name\n---\n<switch>", "hillstone": "Total lldp neighbor number: 0.\n", "cisco_ios": "Total cdp entries displayed : 0\n", "cisco_nxos": "No cdp neighbors\n", "huawei": "Local Intf Neighbor Dev Neighbor Intf Exptime(s)\n---\n", "fortinet": "No LLDP neighbors.\n", "juniper": "Total entries displayed: 0\n", "palo_alto": "Local information:\nLocal interface: ethernet1/1\nNeighbor information:\n"} {
		t.Run(vendor, func(t *testing.T) {
			n, e := topology.ParseNeighbors(neighborPolicyFor(t, vendor), body)
			if e != nil || len(n) != 0 {
				t.Fatalf("%#v %v", n, e)
			}
		})
	}
}

func TestFortinetNestedDescriptionsAndPANMixedBlocks(t *testing.T) {
	config := "config system interface\n    edit \"port1\"\n        set alias ignored\n        set description \"uplink core\"\n        config ipv6\n            config ip6-extra-addr\n                edit \"2001:db8::1/64\"\n                    set description nested\n                next\n            end\n        end\n    next\n    edit \"port2\"\n        set description \"\"\n    next\nend\n"
	d, e := topology.ParseDescriptions(descriptionPolicyFor(t, "fortinet"), config)
	if e != nil || len(d) != 2 || d["port1"] != "uplink core" || d["port2"] != "" {
		t.Fatalf("%#v %v", d, e)
	}
	empty := "Local information:\nLocal interface: ethernet1/13\nNeighbor information:\n"
	full := "Local information:\nLocal interface: ethernet1/14\nNeighbor information:\nChassis ID: 001122334455\nPort ID: Ethernet1/2\nSystem name: peer\n"
	n, e := topology.ParseNeighbors(neighborPolicyFor(t, "palo_alto"), full+empty)
	if e != nil || len(n) != 1 || n[0].LocalInterface != "ethernet1/14" {
		t.Fatalf("%#v %v", n, e)
	}
}

func neighborPolicyFor(tb testing.TB, vendor string) topology.NeighborDiscovery {
	tb.Helper()
	platform, err := vendors.NewBuiltinRegistry().Lookup(vendor)
	if err != nil {
		tb.Fatal(err)
	}
	policy, ok := platform.(topology.NeighborDiscovery)
	if !ok {
		tb.Fatalf("platform %q does not provide neighbor discovery", vendor)
	}
	return policy
}

func descriptionPolicyFor(tb testing.TB, vendor string) topology.DescriptionReader {
	tb.Helper()
	platform, err := vendors.NewBuiltinRegistry().Lookup(vendor)
	if err != nil {
		tb.Fatal(err)
	}
	policy, ok := platform.(topology.DescriptionReader)
	if !ok {
		tb.Fatalf("platform %q does not provide interface description parsing", vendor)
	}
	return policy
}

func neighborFixtures(t *testing.T) map[string]string {
	t.Helper()
	data, e := os.ReadFile("testdata/neighbors.json")
	if e != nil {
		t.Fatal(e)
	}
	var samples map[string]string
	if e = json.Unmarshal(data, &samples); e != nil {
		t.Fatal(e)
	}
	return samples
}

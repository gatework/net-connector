package vendors

import (
	"errors"
	"testing"

	"github.com/gatework/net-connector/facts"
	"github.com/gatework/net-connector/platform"
)

// The outputs below follow the vendors' published command references. They
// fix the parsing contract; they are not captures from production devices.
var factsFixtures = map[string]struct {
	outputs  []string
	expected facts.Facts
	// partial drops the optional lines; only the version must remain.
	partial         []string
	expectedPartial facts.Facts
}{
	"cisco_ios": {
		outputs:         []string{"Cisco IOS Software, C3750 Software (C3750-IPSERVICESK9-M), Version 12.2(55)SE9, RELEASE SOFTWARE (fc1)\r\nROM: Bootstrap program is C3750 boot loader\r\n\r\ncore-sw uptime is 1 week, 2 days, 3 hours, 4 minutes\r\nSystem image file is \"flash:c3750.bin\"\r\n\r\ncisco WS-C3750G-24TS (PowerPC405) processor (revision H0) with 131072K bytes of memory.\r\nProcessor board ID FOC1234X5YZ\r\n"},
		expected:        facts.Facts{Hostname: "core-sw", Model: "WS-C3750G-24TS", Serial: "FOC1234X5YZ", OSVersion: "12.2(55)SE9", Uptime: "1 week, 2 days, 3 hours, 4 minutes"},
		partial:         []string{"Cisco IOS XE Software, Catalyst L3 Switch Software (CAT9K_IOSXE), Version 16.9.4, RELEASE SOFTWARE (fc2)\r\n"},
		expectedPartial: facts.Facts{OSVersion: "16.9.4"},
	},
	"cisco_nxos": {
		outputs:         []string{"Cisco Nexus Operating System (NX-OS) Software\r\nSoftware\r\n  BIOS: version 07.69\r\n  NXOS: version 9.3(8)\r\nHardware\r\n  cisco Nexus9000 C93180YC-EX chassis\r\n  Intel(R) Xeon(R) CPU with 24633476 kB of memory.\r\n  Processor Board ID FDO21120XYZ\r\n\r\n  Device name: n9k-1\r\n  bootflash:   53298520 kB\r\nKernel uptime is 10 day(s), 3 hour(s), 5 minute(s), 20 second(s)\r\n"},
		expected:        facts.Facts{Hostname: "n9k-1", Model: "Nexus9000 C93180YC-EX", Serial: "FDO21120XYZ", OSVersion: "9.3(8)", Uptime: "10 day(s), 3 hour(s), 5 minute(s), 20 second(s)"},
		partial:         []string{"Software\r\n  system:    version 7.0(3)I7(9)\r\n"},
		expectedPartial: facts.Facts{OSVersion: "7.0(3)I7(9)"},
	},
	"h3c": {
		outputs: []string{
			"H3C Comware Software, Version 7.1.070, Release 6126P20\r\nCopyright (c) 2004-2021 New H3C Technologies Co., Ltd. All rights reserved.\r\nH3C S6800-54QF uptime is 12 weeks, 3 days, 4 hours, 5 minutes\r\nLast reboot reason : Cold reboot\r\n",
			" Slot 1 CPU 0:\r\n DEVICE_NAME          : S6800-54QF\r\n DEVICE_SERIAL_NUMBER : 210235A1ABCDEF000001\r\n MAC_ADDRESS          : 00E0-FC00-0001\r\n Fan 1:\r\n DEVICE_NAME          : LSWM1FANSA\r\n DEVICE_SERIAL_NUMBER : 210231A9FAN000000002\r\n",
		},
		expected:        facts.Facts{Model: "S6800-54QF", Serial: "210235A1ABCDEF000001", OSVersion: "7.1.070, Release 6126P20", Uptime: "12 weeks, 3 days, 4 hours, 5 minutes"},
		partial:         []string{"H3C Comware Software, Version 7.1.070, Release 6126P20\r\n", ""},
		expectedPartial: facts.Facts{OSVersion: "7.1.070, Release 6126P20"},
	},
	"huawei": {
		outputs: []string{
			"Huawei Versatile Routing Platform Software\r\nVRP (R) software, Version 5.170 (S5720 V200R011C10SPC600)\r\nCopyright (C) 2000-2018 HUAWEI TECH Co., Ltd.\r\nHUAWEI S5720-28X-SI-AC Routing Switch uptime is 5 weeks, 1 day, 2 hours, 3 minutes\r\n",
			"ESN of slot 0: 2102350DLR10K1000123\r\n",
		},
		expected:        facts.Facts{Model: "S5720-28X-SI-AC", Serial: "2102350DLR10K1000123", OSVersion: "5.170 (S5720 V200R011C10SPC600)", Uptime: "5 weeks, 1 day, 2 hours, 3 minutes"},
		partial:         []string{"VRP (R) software, Version 8.180 (CE6850EI V200R005C10SPC800)\r\n", ""},
		expectedPartial: facts.Facts{OSVersion: "8.180 (CE6850EI V200R005C10SPC800)"},
	},
	"juniper": {
		outputs: []string{
			"Hostname: mx1\r\nModel: mx480\r\nJunos: 20.4R3-S2.6\r\nJUNOS OS Kernel 64-bit  [20210618.f43645e_builder_stable_11]\r\n",
			"Hardware inventory:\r\nItem             Version  Part number  Serial number     Description\r\nChassis                                JN1234567AFA      MX480\r\nMidplane         REV 07   710-017414   ACRA1234          MX480 Midplane\r\n",
		},
		expected:        facts.Facts{Hostname: "mx1", Model: "mx480", Serial: "JN1234567AFA", OSVersion: "20.4R3-S2.6"},
		partial:         []string{"Junos: 18.4R2.7\r\n", ""},
		expectedPartial: facts.Facts{OSVersion: "18.4R2.7"},
	},
	"fortinet": {
		outputs:         []string{"Version: FortiGate-100F v7.0.12,build0523,230606 (GA.M)\r\nVirus-DB: 91.00000(2023-01-01 00:00)\r\nSerial-Number: FG100FTK20012345\r\nBIOS version: 05000007\r\nHostname: fw1\r\nOperation Mode: NAT\r\n"},
		expected:        facts.Facts{Hostname: "fw1", Model: "FortiGate-100F", Serial: "FG100FTK20012345", OSVersion: "v7.0.12,build0523,230606"},
		partial:         []string{"Version: FortiGate-VM64 v7.2.5,build1517,230606 (GA.F)\r\n"},
		expectedPartial: facts.Facts{Model: "FortiGate-VM64", OSVersion: "v7.2.5,build1517,230606"},
	},
}

func TestFactsParsingByPlatform(t *testing.T) {
	for name, fixture := range factsFixtures {
		t.Run(name, func(t *testing.T) {
			collector, ok := lookupPlatform(t, name).(facts.Collector)
			if !ok {
				t.Fatalf("%s does not declare fact collection", name)
			}
			if len(collector.FactsCommands()) != len(fixture.outputs) {
				t.Fatalf("fixture has %d outputs for %d commands", len(fixture.outputs), len(collector.FactsCommands()))
			}
			if got, err := collector.ParseFacts(fixture.outputs); err != nil || got != fixture.expected {
				t.Fatalf("complete output: %+v %v, want %+v", got, err, fixture.expected)
			}
			if got, err := collector.ParseFacts(fixture.partial); err != nil || got != fixture.expectedPartial {
				t.Fatalf("output without optional lines: %+v %v, want %+v", got, err, fixture.expectedPartial)
			}
			unrelated := make([]string, len(fixture.outputs))
			unrelated[0] = "% Unrecognized command found at '^' position.\r\n"
			_, err := collector.ParseFacts(unrelated)
			if !errors.Is(err, platform.ErrParse) && err == nil {
				t.Fatal("unrelated output was accepted as facts")
			}
			var diagnostic platform.DiagnosticMetadata
			if !errors.As(err, &diagnostic) || diagnostic.DiagnosticCode() != "unrecognized_output" {
				t.Fatalf("unrelated output error = %v", err)
			}
		})
	}
}

func TestFactsCommandsAreReadOnlyForEveryDeclaringPlatform(t *testing.T) {
	registry := NewBuiltinRegistry()
	declared := 0
	for _, name := range registry.Names() {
		p := lookupPlatform(t, name)
		if _, ok := p.(facts.Collector); !ok {
			if _, err := facts.Commands(p); !errors.Is(err, facts.ErrUnsupported) {
				t.Errorf("%s: %v", name, err)
			}
			continue
		}
		declared++
		if _, ok := factsFixtures[name]; !ok && name != "h3c_wireless" {
			t.Errorf("%s declares facts without a parsing fixture", name)
		}
		if commands, err := facts.Commands(p); err != nil || len(commands) == 0 {
			t.Errorf("%s fact commands are not read-only for the platform itself: %v", name, err)
		}
	}
	if declared != 7 {
		t.Fatalf("platforms declaring facts = %d, want 7", declared)
	}
}

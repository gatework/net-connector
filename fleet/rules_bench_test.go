package fleet

import (
	"testing"

	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/vendors"
)

func BenchmarkRulesResolve(b *testing.B) {
	rules, err := NewRules(RuleOptions{}, vendors.NewBuiltinRegistry())
	if err != nil {
		b.Fatal(err)
	}
	rows := []inventory.Device{
		{Vendor: "H3C", OS: "Comware", Model: "S7500"},
		{Vendor: "H3C", OS: "Wireless", Model: "WX5000"},
		{Vendor: "Cisco", OS: "IOS XE", Model: "C9300"},
		{Vendor: "Cisco", OS: "NX-OS", Model: "Nexus 9000"},
		{Vendor: "Fortinet", OS: "FortiOS", Model: "FGT 100"},
		{Vendor: "Juniper", OS: "Junos", Model: "SRX"},
		{Vendor: "Unknown", OS: "Unknown", Model: "Unknown"},
	}
	b.ReportAllocs()
	for b.Loop() {
		for _, row := range rows {
			rules.Resolve(row)
		}
	}
}

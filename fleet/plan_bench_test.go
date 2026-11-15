package fleet

import (
	"fmt"
	"testing"

	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/transfer"
	"github.com/gatework/net-connector/vendors"
)

// Include vendor resolution and capability lookup in the timed workload.
func BenchmarkNewPlan(b *testing.B) {
	for _, count := range []int{1000, 10000} {
		b.Run(fmt.Sprint(count), func(b *testing.B) {
			rows := make([]inventory.Device, count)
			for i := range rows {
				rows[i] = inventory.Device{IP: fmt.Sprintf("10.%d.%d.%d", i>>16, (i>>8)&255, i&255), Vendor: "Cisco", OS: "ios"}
				if i%3 == 0 {
					rows[i].Vendor, rows[i].OS = "H3C", "comware"
				}
			}
			rules, err := NewRules(RuleOptions{}, vendors.NewBuiltinRegistry())
			if err != nil {
				b.Fatal(err)
			}
			b.ReportAllocs()
			for b.Loop() {
				plan, err := NewPlan(rows, rules, PlanOptions{Admit: admitConfig})
				if err != nil || len(plan.tasks) != count {
					b.Fatal(err)
				}
			}
		})
	}
}

// BenchmarkTFTPPlanCapabilityPreflight1000 exercises the transfer behavior
// interface without constructing connector profiles during TFTP planning.
func BenchmarkTFTPPlanCapabilityPreflight1000(b *testing.B) {
	rows := make([]inventory.Device, 1000)
	for i := range rows {
		rows[i] = inventory.Device{IP: fmt.Sprintf("10.%d.%d.%d", i>>16, (i>>8)&255, i&255), Vendor: "Cisco", OS: "ios"}
		if i%3 == 0 {
			rows[i].Vendor, rows[i].OS = "H3C", "comware"
		}
	}
	rules, err := NewRules(RuleOptions{}, vendors.NewBuiltinRegistry())
	if err != nil {
		b.Fatal(err)
	}
	options := PlanOptions{
		Admit: admitTFTP,
		Target: func(record Record) (transfer.Target, error) {
			return transfer.Target{TFTPOptions: transfer.TFTPOptions{Server: "192.0.2.9", Path: "archive/" + record.Host + ".cfg"}}, nil
		},
	}
	b.ReportAllocs()
	b.ResetTimer()
	for b.Loop() {
		plan, err := NewPlan(rows, rules, options)
		if err != nil || len(plan.Tasks()) != len(rows) {
			b.Fatalf("tasks=%d err=%v", len(plan.Tasks()), err)
		}
	}
}

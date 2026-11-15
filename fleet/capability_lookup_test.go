package fleet

import (
	"testing"

	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/vendors"
)

func TestPlanLooksUpCapabilitiesOncePerVendorPerPlan(t *testing.T) {
	calls := make(map[string]int)
	profiles := profileRegistry{}
	builtin := vendors.NewBuiltinRegistry()
	for _, name := range builtin.Names() {
		declaration, err := builtin.Lookup(name)
		if err != nil {
			t.Fatal(err)
		}
		profiles[name] = declaration.Terminal()
	}
	registry := &changingRegistry{profiles: profiles, calls: calls, resolver: any(builtin).(PlatformResolver)}
	rules, err := NewRules(RuleOptions{}, registry)
	if err != nil {
		t.Fatal(err)
	}
	rows := []inventory.Device{{IP: "192.0.2.1", Vendor: "Cisco", OS: "ios"}, {IP: "192.0.2.2", Vendor: "Cisco", OS: "ios"}, {IP: "192.0.2.3", Vendor: "H3C"}}
	plan, err := NewPlan(rows, rules, PlanOptions{Admit: admitConfig})
	if err != nil || len(plan.Tasks()) != 3 || calls["cisco_ios"] != 1 || calls["h3c"] != 1 {
		t.Fatalf("calls=%v err=%v", calls, err)
	}
	profile := profiles["cisco_ios"]
	profile.ConfigCommands = nil
	profiles["cisco_ios"] = profile
	profile = profiles["h3c"]
	profile.ConfigCommands = nil
	profiles["h3c"] = profile
	plan, err = NewPlan(rows, rules, PlanOptions{Admit: admitConfig})
	if err != nil || len(plan.Tasks()) != 0 || calls["cisco_ios"] != 2 || calls["h3c"] != 2 {
		t.Fatalf("capabilities leaked between plans: %v %v", calls, err)
	}
}

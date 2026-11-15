package fleet

import (
	"testing"

	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/transfer"
	"github.com/gatework/net-connector/vendors"
)

func TestPlanRulesSamplingAndDuplicates(t *testing.T) {
	rules, e := NewRules(RuleOptions{}, vendors.NewBuiltinRegistry())
	if e != nil {
		t.Fatal(e)
	}
	rows := []inventory.Device{{IP: "192.0.2.2", Vendor: "H3C", Name: "core"}, {IP: "192.0.2.1", Vendor: "H3C"}, {IP: "bad", Vendor: "H3C"}, {IP: "192.0.2.3", Vendor: "Cisco", OS: "ios"}, {IP: "192.0.2.3", Vendor: "Cisco", OS: "ios"}}
	plan, e := NewPlan(rows, rules, PlanOptions{Admit: admitConfig, LimitPerPlatform: 1})
	if e != nil {
		t.Fatal(e)
	}
	tasks := plan.Tasks()
	if len(tasks) != 1 || tasks[0].Device.Host != "192.0.2.1" {
		t.Fatal(tasks)
	}
	entries := plan.Entries()
	if entries[0].Status != "sample_limit" || entries[2].Status != "invalid_address" || entries[3].Status != "duplicate_host" || entries[4].Status != "duplicate_host" {
		t.Fatal(entries)
	}
	tasks[0].Device.Host = "changed"
	if plan.Tasks()[0].Device.Host == "changed" {
		t.Fatal("plan shares mutable slice")
	}
}
func TestPlanTFTPCollisionBeforeCredentials(t *testing.T) {
	rules, _ := NewRules(RuleOptions{}, vendors.NewBuiltinRegistry())
	rows := []inventory.Device{{IP: "192.0.2.1", Vendor: "Palo Alto"}, {IP: "192.0.2.2", Vendor: "Palo Alto"}}
	target := func(Record) (transfer.Target, error) {
		return transfer.Target{TFTPOptions: transfer.TFTPOptions{Server: "192.0.2.9", Path: "running-config.xml"}}, nil
	}
	p, e := NewPlan(rows, rules, PlanOptions{Admit: admitTFTP, Target: target})
	if e != nil {
		t.Fatal(e)
	}
	if len(p.Tasks()) != 1 || p.Entries()[1].Status != "remote_filename_collision" {
		t.Fatal(p.Entries())
	}
	p, e = NewPlan(rows, rules, PlanOptions{Admit: admitTFTP, Target: target, ReuseDestination: reuseTFTP})
	if e != nil || len(p.Tasks()) != 2 {
		t.Fatal(p, e)
	}
	if _, e = NewRules(RuleOptions{HostOverrides: map[string]string{"192.0.2.1": "unknown"}}, profileRegistry{}); e == nil {
		t.Fatal("bad override accepted")
	}
}

func TestPlanSampledTFTPCollisionWinnerAndInventoryOrder(t *testing.T) {
	rules, err := NewRules(RuleOptions{}, vendors.NewBuiltinRegistry())
	if err != nil {
		t.Fatal(err)
	}
	rows := []inventory.Device{{IP: "192.0.2.3", Vendor: "Palo Alto"}, {IP: "192.0.2.1", Vendor: "Palo Alto"}, {IP: "192.0.2.2", Vendor: "Palo Alto"}, {IP: "192.0.2.4", Vendor: "H3C"}}
	target := func(r Record) (transfer.Target, error) {
		path := "running-config.xml"
		if r.Platform == "h3c" {
			path = "h3c.txt"
		}
		return transfer.Target{TFTPOptions: transfer.TFTPOptions{Server: "192.0.2.9", Path: path}}, nil
	}
	for _, tc := range []struct {
		name     string
		limit    int
		winner   string
		statuses []string
	}{{"sampled", 5, "192.0.2.1", []string{"remote_filename_collision", "ready", "remote_filename_collision", "ready"}}, {"all", 0, "192.0.2.3", []string{"ready", "remote_filename_collision", "remote_filename_collision", "ready"}}} {
		t.Run(tc.name, func(t *testing.T) {
			p, err := NewPlan(rows, rules, PlanOptions{Admit: admitTFTP, LimitPerPlatform: tc.limit, Target: target})
			if err != nil {
				t.Fatal(err)
			}
			if len(p.Tasks()) != 2 || p.Tasks()[0].Device.Host != tc.winner || p.Tasks()[1].Index != 3 {
				t.Fatalf("tasks %#v", p.Tasks())
			}
			for i, e := range p.Entries() {
				if e.Device.SourceIP != rows[i].IP || e.Status != tc.statuses[i] {
					t.Fatalf("entry %d: %#v", i, e)
				}
			}
		})
	}
}

func TestPlanFreezesCompleteTransferTargetAndCollisionUsesRemotePath(t *testing.T) {
	rules, _ := NewRules(RuleOptions{}, vendors.NewBuiltinRegistry())
	target := transfer.Target{TFTPOptions: transfer.TFTPOptions{Server: "192.0.2.9", Path: "config.cfg", SourceFile: "flash:/startup.cfg", SourceInterface: "management", VRF: "mgt"}, Root: "/archive"}
	p, err := NewPlan([]inventory.Device{{IP: "192.0.2.1", Vendor: "H3C"}, {IP: "192.0.2.2", Vendor: "H3C"}}, rules, PlanOptions{Admit: admitTFTP, Target: func(r Record) (transfer.Target, error) {
		adjusted := target
		if r.Host == "192.0.2.2" {
			adjusted.Root = "/different"
			adjusted.VRF = "different"
		}
		return adjusted, nil
	}})
	if err != nil {
		t.Fatal(err)
	}
	target.Path = "changed.cfg"
	tasks := p.Tasks()
	if len(tasks) != 1 || tasks[0].Target.Path != "config.cfg" || tasks[0].Target.SourceFile != "flash:/startup.cfg" || tasks[0].Target.Root != "/archive" || p.Entries()[1].Status != "remote_filename_collision" {
		t.Fatal(tasks, p.Entries())
	}
	tasks[0].Target.Path = "changed"
	if p.Tasks()[0].Target.Path != "config.cfg" {
		t.Fatal("plan target mutated")
	}
}

func TestSamplingCountsOnlyAdmittedDevices(t *testing.T) {
	rules, err := NewRules(RuleOptions{}, vendors.NewBuiltinRegistry())
	if err != nil {
		t.Fatal(err)
	}
	rows := []inventory.Device{{IP: "192.0.2.1", Vendor: "H3C"}, {IP: "192.0.2.2", Vendor: "H3C"}, {IP: "192.0.2.3", Vendor: "H3C"}}
	admit := func(r Record, _ platform.Platform) string {
		if r.Host == "192.0.2.1" {
			return "missing_script"
		}
		return ""
	}
	plan, err := NewPlan(rows, rules, PlanOptions{Admit: admit, LimitPerPlatform: 1})
	if err != nil {
		t.Fatal(err)
	}
	entries := plan.Entries()
	if entries[0].Status != "missing_script" || entries[1].Status != "ready" || entries[2].Status != "sample_limit" {
		t.Fatalf("the sample was spent on a device the operation skipped: %+v", entries)
	}
	if tasks := plan.Tasks(); len(tasks) != 1 || tasks[0].Device.Host != "192.0.2.2" {
		t.Fatalf("tasks = %+v", tasks)
	}
}

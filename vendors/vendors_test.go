package vendors_test

import (
	"testing"

	"github.com/gatework/net-connector/driver"
	"github.com/gatework/net-connector/vendors"
	"github.com/gatework/netops/device"
	"github.com/gatework/netops/facts"
)

func TestClassify(t *testing.T) {
	t.Parallel()
	r := vendors.Builtin()
	tests := []struct {
		id   device.Identity
		want string
	}{
		{device.Identity{Vendor: "H3C", OS: "Comware", Model: "S6850-56HF"}, "h3c"},
		{device.Identity{Vendor: "H3C", OS: "Comware", Model: "WX5540H"}, "h3c_wireless"},
		{device.Identity{Vendor: "h3c", OS: "comware-wlan"}, "h3c_wireless"},
		{device.Identity{Vendor: "Cisco", OS: "NX-OS", Model: "N9K-C93180YC-EX"}, "cisco_nxos"},
		{device.Identity{Vendor: "cisco", OS: "", Model: "Nexus 9000"}, "cisco_nxos"},
		{device.Identity{Vendor: "Cisco", OS: "IOS-XE", Model: "C9300"}, "cisco_ios"},
		{device.Identity{Vendor: "Huawei", OS: "VRP", Model: "CE6881"}, "huawei"},
		{device.Identity{Vendor: "Juniper", OS: "JunOS", Model: "EX4300"}, "juniper"},
		{device.Identity{Vendor: "Palo Alto Networks", OS: "PAN-OS"}, "palo_alto"},
		{device.Identity{Vendor: "Fortinet", OS: "FortiOS"}, "fortinet"},
		{device.Identity{Vendor: "Hillstone"}, "hillstone"},
		{device.Identity{Vendor: "Radware"}, "radware"},
		{device.Identity{Vendor: "Centec"}, "centec"},
		{device.Identity{Vendor: "Topsec"}, "topsec"},
		{device.Identity{Vendor: "Juniper", OS: "ScreenOS"}, ""},
		{device.Identity{Vendor: "Acme"}, ""},
	}
	for _, tt := range tests {
		got, _ := r.Classify(tt.id)
		if got != tt.want {
			t.Errorf("%+v → %q, want %q", tt.id, got, tt.want)
		}
	}
}

// TestCapabilities pins what each platform declares. Adding a capability
// needs dialogue evidence in this package's tests first.
func TestCapabilities(t *testing.T) {
	t.Parallel()
	want := map[string][]string{
		"h3c_wireless": {"config", "save", "export", "readonly"},
		"h3c":          {"config", "save", "export", "readonly"},
		"cisco_nxos":   {"config", "save", "export", "checkpoint", "readonly"},
		"cisco_ios":    {"config", "save", "export", "readonly"},
		"radware":      {"config", "login", "readonly"},
		"palo_alto":    {"config", "commit", "login", "readonly"},
		"huawei":       {"config", "save", "export", "readonly"},
		"hillstone":    {"config", "save", "login", "readonly"},
		"centec":       {"config", "save", "readonly"},
		"topsec":       {"config", "readonly"},
		"fortinet":     {"config", "readonly"},
		"juniper":      {"config", "commit", "readonly"},
	}
	r := vendors.Builtin()
	for _, key := range r.Platforms() {
		d, _ := r.Lookup(key)
		var got []string
		for _, c := range driver.Capabilities(d) {
			got = append(got, string(c))
		}
		if !equal(got, want[key]) {
			t.Errorf("%s declares %v, want %v", key, got, want[key])
		}
		if !has[driver.Classifier](d) {
			t.Errorf("%s has no classifier", key)
		}
		if err := d.Grammar().Validate(); err != nil {
			t.Errorf("%s: %v", key, err)
		}
	}
	if len(r.Platforms()) != len(want) {
		t.Errorf("platforms = %v", r.Platforms())
	}
}

func has[C any](d driver.Driver) bool { _, ok := driver.As[C](d); return ok }

func equal(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestReadOnly(t *testing.T) {
	t.Parallel()
	h3c, _ := vendors.Builtin().Lookup("h3c")
	ro, _ := driver.As[driver.ReadOnly](h3c)
	for cmd, want := range map[string]bool{
		"display interface brief":               true,
		"dis cur | include sysname":             true,
		"display current-configuration > a.cfg": false,
		"display cur | redirect flash:/x":       false,
		"reset saved-configuration":             false,
		"system-view":                           false,
	} {
		if ro.ReadOnly(cmd) != want {
			t.Errorf("%q read-only = %v", cmd, !want)
		}
	}
}

// Every netops facts command must be read-only by the platform's own
// declaration, so collecting facts never sends a write.
func TestFactsCommandsAreReadOnly(t *testing.T) {
	t.Parallel()
	r := vendors.Builtin()
	for _, platform := range facts.Platforms() {
		d, err := r.Lookup(platform)
		if err != nil {
			t.Errorf("facts probe for unknown platform %s", platform)
			continue
		}
		ro, ok := driver.As[driver.ReadOnly](d)
		p, _ := facts.Lookup(platform)
		for _, cmd := range p.Commands {
			if !ok || !ro.ReadOnly(cmd) {
				t.Errorf("%s: facts command %q is not read-only", platform, cmd)
			}
		}
	}
}

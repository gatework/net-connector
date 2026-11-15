package fleet

import (
	"slices"
	"testing"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/vendors"
)

type profileRegistry map[string]connector.Terminal

type changingRegistry struct {
	profiles profileRegistry
	calls    map[string]int
	resolver PlatformResolver
}

type inventoryResolvingRegistry struct{ profileRegistry }

func (inventoryResolvingRegistry) ResolvePlatform(identity platform.Identity) (string, bool) {
	if identity.Vendor == "Lab Platform" {
		return "fixture", true
	}
	return "", false
}

func TestRulesUseOptionalRegistryInventoryResolver(t *testing.T) {
	registry := inventoryResolvingRegistry{profileRegistry{"fixture": {Name: "fixture"}}}
	rules, err := NewRules(RuleOptions{}, registry)
	if err != nil {
		t.Fatal(err)
	}
	if got := rules.Resolve(inventory.Device{IP: "192.0.2.9", Vendor: "Lab Platform"}); got != "fixture" {
		t.Fatalf("resolved platform = %q, want fixture", got)
	}
}

func TestRulesKeepConfiguredIdentityPrecedence(t *testing.T) {
	operatingSystem := "ios"
	rules, err := NewRules(RuleOptions{
		HostOverrides:     map[string]string{"192.0.2.1": "fortinet"},
		PlatformOverrides: map[string]string{"cisco": "huawei", "arista": "juniper"},
		Mappings:          []Mapping{{Vendor: "cisco", Platform: "hillstone", OS: &operatingSystem}, {Vendor: "arista", Platform: "centec"}},
	}, vendors.NewBuiltinRegistry())
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		device inventory.Device
		want   string
	}{
		{inventory.Device{IP: "192.0.2.1", Vendor: "Cisco", OS: "IOS"}, "fortinet"},
		{inventory.Device{IP: "192.0.2.2", Vendor: "Cisco", OS: "IOS"}, "hillstone"},
		{inventory.Device{IP: "192.0.2.3", Vendor: "Arista"}, "centec"},
		{inventory.Device{IP: "192.0.2.4", Vendor: "Cisco Systems", OS: "IOS XE"}, "cisco_ios"},
	} {
		if got := rules.Resolve(tc.device); got != tc.want {
			t.Fatalf("Resolve(%+v) = %q, want %q", tc.device, got, tc.want)
		}
	}
}

func (r *changingRegistry) Names() []string { return r.profiles.Names() }
func (r *changingRegistry) ResolvePlatform(identity platform.Identity) (string, bool) {
	if r.resolver == nil {
		return "", false
	}
	return r.resolver.ResolvePlatform(identity)
}
func (r *changingRegistry) Lookup(name string) (platform.Platform, error) {
	r.calls[name]++
	return r.profiles.Lookup(name)
}

func (r profileRegistry) Names() []string {
	names := make([]string, 0, len(r))
	for name := range r {
		names = append(names, name)
	}
	slices.Sort(names)
	return names
}

func (r profileRegistry) Lookup(name string) (platform.Platform, error) {
	profile, ok := r[name]
	if !ok {
		return nil, connector.ErrUnsupported
	}
	return testPlatform{connector.StaticDriver{Grammar: profile}}, nil
}

type testPlatform struct{ connector.StaticDriver }

func (d testPlatform) Name() string                        { return d.Grammar.Name }
func (testPlatform) MatchInventory(platform.Identity) bool { return false }

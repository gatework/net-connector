package vendors_test

import (
	"testing"

	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/topology"
	"github.com/gatework/net-connector/vendors/centec"
	"github.com/gatework/net-connector/vendors/cisco"
	"github.com/gatework/net-connector/vendors/fortinet"
	"github.com/gatework/net-connector/vendors/h3c"
	"github.com/gatework/net-connector/vendors/hillstone"
	"github.com/gatework/net-connector/vendors/huawei"
	"github.com/gatework/net-connector/vendors/juniper"
	"github.com/gatework/net-connector/vendors/paloalto"
	"github.com/gatework/net-connector/vendors/radware"
	"github.com/gatework/net-connector/vendors/topsec"
)

func TestFamilyPackagesExposePlatformConstructors(t *testing.T) {
	platforms := []struct {
		name  string
		value platform.Platform
	}{
		{name: "centec", value: centec.New()},
		{name: "cisco_ios", value: cisco.IOS()},
		{name: "cisco_nxos", value: cisco.NXOS()},
		{name: "fortinet", value: fortinet.New()},
		{name: "h3c", value: h3c.New()},
		{name: "h3c_wireless", value: h3c.Wireless()},
		{name: "hillstone", value: hillstone.New()},
		{name: "huawei", value: huawei.New()},
		{name: "juniper", value: juniper.New()},
		{name: "palo_alto", value: paloalto.New()},
		{name: "radware", value: radware.New()},
		{name: "topsec", value: topsec.New()},
	}
	var _ topology.DescriptionReader = h3c.New()
	var _ topology.DescriptionWriter = h3c.New()
	if got := topology.InterfaceIdentity(h3c.New()).ConfigName("Te1/0/2"); got != "TenGigabitEthernet1/0/2" {
		t.Fatalf("configuration interface = %q", got)
	}

	for _, tc := range platforms {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.value.Name(); got != tc.name {
				t.Fatalf("platform name = %q, want %q", got, tc.name)
			}
		})
	}
}

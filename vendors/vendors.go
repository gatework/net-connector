// Package vendors assembles the built-in platform registry.
//
//	key           type               capabilities
//	h3c_wireless  h3c.Wireless       config, save, export
//	h3c           h3c.Switch         config, save, export
//	cisco_nxos    cisco.NXOS         config, save, export, checkpoint
//	cisco_ios     cisco.IOS          config, save, export
//	radware       radware.Alteon     config, login state
//	palo_alto     paloalto.PANOS     config (guarded), commit, login state
//	huawei        huawei.VRP         config, save, export
//	hillstone     hillstone.StoneOS  config, save, login state
//	centec        centec.CNOS        config, save
//	topsec        topsec.TOS         config
//	fortinet      fortinet.FortiOS   config
//	juniper       juniper.Junos      config, commit
//
// Declared capabilities follow the dialogue evidence carried over from the
// retired implementation; none is proven on real devices by unit tests.
package vendors

import (
	"sync"

	"github.com/gatework/net-connector/driver"
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

// Builtin returns the built-in registry. The order is the inventory
// classification priority: specific platforms (wireless controllers,
// NX-OS) come before their general family.
var Builtin = sync.OnceValue(func() *driver.Registry {
	r, err := driver.NewRegistry(
		h3c.NewWireless(), h3c.New(), cisco.NewNXOS(), cisco.NewIOS(), radware.New(),
		paloalto.New(), huawei.New(), hillstone.New(), centec.New(), topsec.New(),
		fortinet.New(), juniper.New(),
	)
	if err != nil {
		panic(err)
	}
	return r
})

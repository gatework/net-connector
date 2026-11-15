package juniper

import (
	"github.com/gatework/net-connector/internal/ifname"
	"github.com/gatework/net-connector/vendors/internal/topoparse"
)

func topologyParser() topoparse.Parser {
	return topoparse.Parser{
		NeighborTemplate:    "juniper/show_lldp_neighbors_detail.textfsm",
		DescriptionTemplate: "juniper/show_configuration_display_set.textfsm",
		Protocol:            topoparse.ProtocolLLDP,
		CountNeighbors:      neighborCount,
		CanonicalInterface:  ifname.Key,
		AppendInterfaceUnit: true,
		DecodeDescription:   true,
		StrictDescription:   true,
	}
}

func neighborCount(text string) (int, bool) {
	empty := topoparse.Pattern(`(?im)^\s*(?:No LLDP neighbors\.?|Total entries displayed\s*:\s*0)\s*$`).MatchString(text)
	validRecord := topoparse.Pattern(`(?im)^\s*(?:Local Interface|Chassis (?:ID|Id)|Port ID|System name)\s*:`).MatchString(text)
	return topoparse.Count(`(?im)^\s*Local Interface\s*:`, text), empty && !validRecord
}

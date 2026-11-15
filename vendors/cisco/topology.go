package cisco

import (
	"github.com/gatework/net-connector/internal/ifname"
	"github.com/gatework/net-connector/vendors/internal/topoparse"
)

func iosTopologyParser() topoparse.Parser {
	return topoparse.Parser{
		NeighborTemplate:     "cisco/show_cdp_neighbors_detail.textfsm",
		DescriptionTemplate:  "cisco/show_running_config.textfsm",
		Protocol:             topoparse.ProtocolCDP,
		CountNeighbors:       iosNeighborCount,
		ValidateDescriptions: topoparse.ValidateInterfaceRows,
		CanonicalInterface:   ifname.Key,
	}
}

func nxosTopologyParser() topoparse.Parser {
	return topoparse.Parser{
		NeighborTemplate:     "cisco_nxos/show_cdp_neighbors_detail.textfsm",
		DescriptionTemplate:  "cisco_nxos/show_running_config.textfsm",
		Protocol:             topoparse.ProtocolCDP,
		CountNeighbors:       nxosNeighborCount,
		ValidateDescriptions: topoparse.ValidateInterfaceRows,
		CanonicalInterface:   ifname.Key,
	}
}

func iosNeighborCount(text string) (int, bool) {
	return topoparse.Count(`(?im)^\s*Device ID:\s*\S+`, text), topoparse.Pattern(`(?i)Total cdp entries displayed\s*:\s*0|no cdp neighbors`).MatchString(text)
}

func nxosNeighborCount(text string) (int, bool) {
	return topoparse.Count(`(?im)^\s*Device[ -]ID:`, text), topoparse.Pattern(`(?i)Total cdp entries displayed\s*:\s*0|no cdp neighbors`).MatchString(text)
}

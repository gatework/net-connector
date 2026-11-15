package huawei

import (
	"strings"

	"github.com/gatework/net-connector/internal/ifname"
	"github.com/gatework/net-connector/vendors/internal/topoparse"
)

var headerPattern = topoparse.Pattern(`(?i)^[ \t]*Local Intf[ \t]+Neighbor Dev[ \t]+Neighbor Intf[ \t]+Exptime`)

func topologyParser() topoparse.Parser {
	return topoparse.Parser{
		NeighborTemplate:     "huawei/display_lldp_neighbor_brief.textfsm",
		DescriptionTemplate:  "huawei/display_current_configuration.textfsm",
		Protocol:             topoparse.ProtocolLLDP,
		CountNeighbors:       neighborCount,
		ValidateDescriptions: topoparse.ValidateInterfaceRows,
		CanonicalInterface: func(name string) string {
			return ifname.Key(strings.NewReplacer(" ", "", "\t", "").Replace(name))
		},
	}
}

func neighborCount(text string) (int, bool) {
	lines, seen := topoparse.TableLines(text, headerPattern)
	return len(lines), seen && len(lines) == 0
}

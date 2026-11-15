package h3c

import (
	"strings"

	"github.com/gatework/net-connector/internal/ifname"
	"github.com/gatework/net-connector/vendors/internal/topoparse"
)

var headerPattern = topoparse.Pattern(`(?i)^\s*(?:System Name\s+Local Interface\b|(?:Local Interface|LocalIf)\s+)`)

func topologyParser() topoparse.Parser {
	return topoparse.Parser{
		NeighborTemplate:     "h3c/display_lldp_neighbor_information_list.textfsm",
		DescriptionTemplate:  "h3c/display_current_configuration.textfsm",
		Protocol:             topoparse.ProtocolLLDP,
		CountNeighbors:       neighborCount,
		ValidateDescriptions: topoparse.ValidateInterfaceRows,
		CanonicalInterface:   ifname.Key,
	}
}

func neighborCount(text string) (int, bool) {
	lines, seen := topoparse.TableLines(text, headerPattern)
	if !seen {
		return -1, false
	}
	column := 0
	if topoparse.Pattern(`(?im)^[ \t]*System Name[ \t]+Local Interface\b`).MatchString(text) {
		column = 1
	}
	pattern := topoparse.Pattern(`(?i)^(?:[A-Za-z][A-Za-z-]*\d+(?:/\d+)+|(?:Bridge-Aggregation|BAGG|Route-Aggregation|RAGG)\d+)(?:[:.]\d+)*$`)
	for _, line := range lines {
		fields := strings.Fields(line)
		if len(fields) <= column || !pattern.MatchString(fields[column]) {
			return -1, false
		}
	}
	return len(lines), len(lines) == 0
}

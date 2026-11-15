package hillstone

import (
	"strconv"
	"strings"

	"github.com/gatework/net-connector/internal/ifname"
	"github.com/gatework/net-connector/vendors/internal/topoparse"
)

func topologyParser() topoparse.Parser {
	return topoparse.Parser{
		NeighborTemplate:     "hillstone/show_lldp_neighbor_information.textfsm",
		DescriptionTemplate:  "hillstone/show_configuration_running.textfsm",
		Protocol:             topoparse.ProtocolLLDP,
		CountNeighbors:       neighborCount,
		ValidateDescriptions: topoparse.ValidateInterfaceRows,
		CanonicalInterface:   ifname.Key,
	}
}

func neighborCount(text string) (int, bool) {
	lines := []string{}
	for line := range strings.SplitSeq(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || line == "show lldp neighbor-information" || topoparse.Pattern(`(?i)^(?:System Name\s+Local Interface\b|Total lldp neighbor number:\s*\d+\.?$|[-=+ ]+$|\S+(?:#|\([MBF]\))$)`).MatchString(line) {
			continue
		}
		lines = append(lines, line)
	}
	for _, line := range lines {
		if !topoparse.Pattern(`(?i)^\S+\s+(?:(?:x?ethernet|eth|xe)\d+/\d+|(?:aggregate|agg)\d+)(?:\.\d+)?\s`).MatchString(line) {
			return -1, false
		}
	}
	if match := topoparse.Pattern(`(?i)Total lldp neighbor number:\s*(\d+)`).FindStringSubmatch(text); len(match) > 0 {
		n, _ := strconv.Atoi(match[1])
		if n != len(lines) {
			return -1, false
		}
	}
	return len(lines), len(lines) == 0 && topoparse.Pattern(`(?i)Total lldp neighbor number:\s*0\b|System Name\s+Local Interface`).MatchString(text)
}

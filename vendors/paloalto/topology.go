package paloalto

import (
	"strings"

	"github.com/gatework/net-connector/internal/ifname"
	"github.com/gatework/net-connector/vendors/internal/topoparse"
)

func topologyParser() topoparse.Parser {
	return topoparse.Parser{
		NeighborTemplate:    "palo_alto/show_lldp_neighbors_all.textfsm",
		DescriptionTemplate: "palo_alto/show.textfsm",
		Protocol:            topoparse.ProtocolLLDP,
		CountNeighbors:      neighborCount,
		CanonicalInterface:  ifname.Key,
		StrictDescription:   true,
	}
}

func neighborCount(text string) (int, bool) {
	blocks := topoparse.Pattern(`(?im)^\s*Local information:\s*$`).Split(text, -1)
	total, empty := 0, 0
	for _, block := range blocks {
		if !topoparse.Pattern(`(?im)^\s*Local interface:\s*\S+`).MatchString(block) {
			continue
		}
		total++
		parts := topoparse.Pattern(`(?im)^\s*Neighbor information:\s*$`).Split(block, 2)
		if len(parts) != 2 {
			continue
		}
		blank := true
		for line := range strings.SplitSeq(parts[1], "\n") {
			line = strings.TrimSpace(line)
			if line != "" && !topoparse.Pattern(`^\S+[>#]\s*$`).MatchString(line) {
				blank = false
			}
		}
		if blank {
			empty++
		}
	}
	return total - empty, topoparse.Pattern(`(?i)No LLDP neighbors`).MatchString(text) || total > 0 && total == empty
}

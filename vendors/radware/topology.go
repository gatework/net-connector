package radware

import (
	"github.com/gatework/net-connector/internal/ifname"
	"github.com/gatework/net-connector/vendors/internal/topoparse"
)

func topologyParser() topoparse.Parser {
	return topoparse.Parser{
		DescriptionTemplate: "radware/cfg_dump.textfsm",
		CanonicalInterface:  ifname.Key,
		StrictDescription:   true,
	}
}

package hillstone_test

import (
	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/topology"
	"github.com/gatework/net-connector/transfer"
	"github.com/gatework/net-connector/vendors/hillstone"
)

// The declared capabilities are checked at compile time: a renamed or
// mistyped method fails the build instead of silently dropping a capability.
// Keep this list in step with the capability matrix in vendors/README.md.
var (
	_ platform.Platform          = hillstone.Platform{}
	_ topology.NeighborDiscovery = hillstone.Platform{}
	_ topology.DescriptionReader = hillstone.Platform{}
	_ topology.InterfaceIdentity = hillstone.Platform{}
	_ topology.DescriptionWriter = hillstone.Platform{}
	_ transfer.TFTPPolicy        = hillstone.Platform{}
)

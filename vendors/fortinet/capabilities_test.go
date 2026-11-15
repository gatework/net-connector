package fortinet_test

import (
	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/topology"
	"github.com/gatework/net-connector/transfer"
	"github.com/gatework/net-connector/vendors/fortinet"
)

// The declared capabilities are checked at compile time: a renamed or
// mistyped method fails the build instead of silently dropping a capability.
// Keep this list in step with the capability matrix in vendors/README.md.
var (
	_ platform.Platform          = fortinet.Platform{}
	_ topology.NeighborDiscovery = fortinet.Platform{}
	_ topology.DescriptionReader = fortinet.Platform{}
	_ topology.InterfaceIdentity = fortinet.Platform{}
	_ transfer.TFTPPolicy        = fortinet.Platform{}
)

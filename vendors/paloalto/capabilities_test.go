package paloalto_test

import (
	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/topology"
	"github.com/gatework/net-connector/transfer"
	"github.com/gatework/net-connector/vendors/paloalto"
)

// The declared capabilities are checked at compile time: a renamed or
// mistyped method fails the build instead of silently dropping a capability.
// Keep this list in step with the capability matrix in vendors/README.md.
var (
	_ platform.Platform          = paloalto.Platform{}
	_ topology.NeighborDiscovery = paloalto.Platform{}
	_ topology.DescriptionReader = paloalto.Platform{}
	_ topology.InterfaceIdentity = paloalto.Platform{}
	_ topology.WriteRestriction  = paloalto.Platform{}
	_ transfer.TFTPPolicy        = paloalto.Platform{}
	_ connector.Committer        = paloalto.Platform{}
)

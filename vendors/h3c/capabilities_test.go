package h3c_test

import (
	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/topology"
	"github.com/gatework/net-connector/transfer"
	"github.com/gatework/net-connector/vendors/h3c"
)

// The declared capabilities are checked at compile time: a renamed or
// mistyped method fails the build instead of silently dropping a capability.
// Keep this list in step with the capability matrix in vendors/README.md.
var (
	_ platform.Platform           = h3c.Platform{}
	_ topology.NeighborDiscovery  = h3c.Platform{}
	_ topology.DescriptionReader  = h3c.Platform{}
	_ topology.InterfaceIdentity  = h3c.Platform{}
	_ topology.DescriptionWriter  = h3c.Platform{}
	_ transfer.TFTPPolicy         = h3c.Platform{}
	_ transfer.SourceFileResolver = h3c.Platform{}
	_ connector.CommandPreparer   = h3c.Platform{}
	_ connector.CommandObserver   = h3c.Platform{}
	_ platform.Platform           = h3c.WirelessPlatform{}
	_ topology.NeighborDiscovery  = h3c.WirelessPlatform{}
	_ topology.DescriptionReader  = h3c.WirelessPlatform{}
	_ topology.InterfaceIdentity  = h3c.WirelessPlatform{}
	_ topology.DescriptionWriter  = h3c.WirelessPlatform{}
	_ transfer.TFTPPolicy         = h3c.WirelessPlatform{}
	_ transfer.SourceFileResolver = h3c.WirelessPlatform{}
	_ connector.CommandPreparer   = h3c.WirelessPlatform{}
	_ connector.CommandObserver   = h3c.WirelessPlatform{}
)

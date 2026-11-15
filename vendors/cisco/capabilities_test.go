package cisco_test

import (
	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/topology"
	"github.com/gatework/net-connector/transfer"
	"github.com/gatework/net-connector/vendors/cisco"
)

// The declared capabilities are checked at compile time: a renamed or
// mistyped method fails the build instead of silently dropping a capability.
// Keep this list in step with the capability matrix in vendors/README.md.
var (
	_ platform.Platform          = cisco.IOSPlatform{}
	_ topology.NeighborDiscovery = cisco.IOSPlatform{}
	_ topology.DescriptionReader = cisco.IOSPlatform{}
	_ topology.InterfaceIdentity = cisco.IOSPlatform{}
	_ topology.DescriptionWriter = cisco.IOSPlatform{}
	_ transfer.TFTPPolicy        = cisco.IOSPlatform{}
	_ platform.Platform          = cisco.NXOSPlatform{}
	_ topology.NeighborDiscovery = cisco.NXOSPlatform{}
	_ topology.DescriptionReader = cisco.NXOSPlatform{}
	_ topology.InterfaceIdentity = cisco.NXOSPlatform{}
	_ topology.DescriptionWriter = cisco.NXOSPlatform{}
	_ transfer.TFTPPolicy        = cisco.NXOSPlatform{}
)

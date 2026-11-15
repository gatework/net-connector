package juniper_test

import (
	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/topology"
	"github.com/gatework/net-connector/transfer"
	"github.com/gatework/net-connector/vendors/juniper"
)

// The declared capabilities are checked at compile time: a renamed or
// mistyped method fails the build instead of silently dropping a capability.
// Keep this list in step with the capability matrix in vendors/README.md.
var (
	_ platform.Platform           = juniper.Platform{}
	_ topology.NeighborDiscovery  = juniper.Platform{}
	_ topology.DescriptionReader  = juniper.Platform{}
	_ topology.InterfaceIdentity  = juniper.Platform{}
	_ topology.WriteRestriction   = juniper.Platform{}
	_ transfer.RemoteBackupPolicy = juniper.Platform{}
	_ connector.Committer         = juniper.Platform{}
)

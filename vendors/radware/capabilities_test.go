package radware_test

import (
	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/topology"
	"github.com/gatework/net-connector/transfer"
	"github.com/gatework/net-connector/vendors/radware"
)

// The declared capabilities are checked at compile time: a renamed or
// mistyped method fails the build instead of silently dropping a capability.
// Keep this list in step with the capability matrix in vendors/README.md.
var (
	_ platform.Platform          = radware.Platform{}
	_ topology.DescriptionReader = radware.Platform{}
	_ topology.InterfaceIdentity = radware.Platform{}
	_ transfer.TFTPPolicy        = radware.Platform{}
	_ connector.LoginInspector   = radware.Platform{}
)

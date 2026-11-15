package topsec_test

import (
	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/vendors/topsec"
)

// The declared capabilities are checked at compile time: a renamed or
// mistyped method fails the build instead of silently dropping a capability.
// Keep this list in step with the capability matrix in vendors/README.md.
var (
	_ platform.Platform = topsec.Platform{}
)

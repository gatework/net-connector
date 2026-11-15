package paloalto

import (
	"regexp"

	"github.com/gatework/net-connector/platform"
)

var labelPattern = regexp.MustCompile(`palo\s*alto|paloalto`)

// MatchInventory reports whether an inventory identity belongs to this platform.
func (Platform) MatchInventory(identity platform.Identity) bool {
	return labelPattern.MatchString(identity.Vendor)
}

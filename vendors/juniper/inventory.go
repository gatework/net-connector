package juniper

import (
	"regexp"

	"github.com/gatework/net-connector/platform"
)

var labelPattern = regexp.MustCompile(`\bjuniper\b`)

// MatchInventory reports whether an inventory identity belongs to this platform.
func (Platform) MatchInventory(identity platform.Identity) bool {
	return labelPattern.MatchString(identity.Vendor) && identity.OS == "junos"
}

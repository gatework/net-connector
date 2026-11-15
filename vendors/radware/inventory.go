package radware

import (
	"regexp"

	"github.com/gatework/net-connector/platform"
)

var labelPattern = regexp.MustCompile(`\bradware\b`)

// MatchInventory reports whether an inventory identity belongs to this platform.
func (Platform) MatchInventory(identity platform.Identity) bool {
	return labelPattern.MatchString(identity.Vendor)
}

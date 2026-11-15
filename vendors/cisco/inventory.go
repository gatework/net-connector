package cisco

import (
	"regexp"

	"github.com/gatework/net-connector/platform"
)

var (
	labelPattern = regexp.MustCompile(`\bcisco\b`)
	nxOS         = regexp.MustCompile(`nx\s*os|nexus`)
	nexusModel   = regexp.MustCompile(`\bnexus\b|\bn\s*[3579]k\b`)
	iosOS        = regexp.MustCompile(`\bios\b|\bios\s*xe\b`)
)

// MatchInventory reports whether an inventory identity is Cisco NX-OS.
func (NXOSPlatform) MatchInventory(identity platform.Identity) bool {
	return labelPattern.MatchString(identity.Vendor) &&
		(nxOS.MatchString(identity.OS) || nexusModel.MatchString(identity.Model))
}

// MatchInventory reports whether an inventory identity is Cisco IOS.
func (IOSPlatform) MatchInventory(identity platform.Identity) bool {
	return labelPattern.MatchString(identity.Vendor) && iosOS.MatchString(identity.OS)
}

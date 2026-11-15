package h3c

import (
	"regexp"

	"github.com/gatework/net-connector/platform"
)

var (
	wirelessOSPattern    = regexp.MustCompile(`wireless|wlan`)
	wirelessModelPattern = regexp.MustCompile(`^(h3c\s+)?(wx|ac)\s*\d`)
	modelPattern         = regexp.MustCompile(`^h3c\s+\S`)
	labelPattern         = regexp.MustCompile(`\bh3c\b`)
)

// MatchInventory reports whether an inventory identity belongs to H3C Comware.
func (Platform) MatchInventory(identity platform.Identity) bool {
	return labelPattern.MatchString(identity.Vendor) ||
		identity.OS == "comware" && modelPattern.MatchString(identity.Model)
}

// MatchInventory reports whether an H3C identity is a wireless controller.
func (w WirelessPlatform) MatchInventory(identity platform.Identity) bool {
	return w.Platform.MatchInventory(identity) && (wirelessOSPattern.MatchString(identity.OS) || wirelessModelPattern.MatchString(identity.Model))
}

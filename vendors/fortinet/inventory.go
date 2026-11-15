package fortinet

import (
	"regexp"

	"github.com/gatework/net-connector/platform"
)

var (
	labelPattern   = regexp.MustCompile(`\bfortinet\b|\bfortigate\b`)
	fortigateLabel = regexp.MustCompile(`\bfortigate\b`)
	fortigateModel = regexp.MustCompile(`^(fortigate|fgt)\s*\d`)
)

// MatchInventory reports whether an inventory identity belongs to this platform.
func (Platform) MatchInventory(identity platform.Identity) bool {
	return labelPattern.MatchString(identity.Vendor) &&
		(identity.OS == "fortios" || fortigateLabel.MatchString(identity.Vendor) || fortigateModel.MatchString(identity.Model))
}

package topology

import (
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/gatework/net-connector/internal/ifname"
)

// InterfaceKey normalizes equivalent interface spellings for comparison.
func InterfaceKey(name string) string { return ifname.Key(name) }

// ShortInterface abbreviates an interface name and optionally lowercases it.
func ShortInterface(name string, lowercase bool) string {
	n, _ := ifname.Short(name)
	if lowercase {
		n = strings.ToLower(n)
	}
	return n
}

// EquivalentDescription compares text and recognized trailing interface names.
func EquivalentDescription(current, expected string) bool {
	if strings.EqualFold(current, expected) {
		return true
	}
	i, j := strings.LastIndex(current, "_"), strings.LastIndex(expected, "_")
	if i < 0 || j < 0 || !strings.EqualFold(current[:i], expected[:j]) {
		return false
	}
	a, ok := ifname.Canonical(current[i+1:])
	b, other := ifname.Canonical(expected[j+1:])
	return ok && other && strings.EqualFold(a, b)
}

// ValidateDescription rejects text unsafe for a description command.
func ValidateDescription(value string) error {
	if len(value) < 1 || len(value) > 80 || !utf8.ValidString(value) {
		return ErrInvalid
	}
	for _, r := range value {
		if !unicode.IsLetter(r) && !unicode.IsNumber(r) && !strings.ContainsRune("_.: /-", r) {
			return ErrInvalid
		}
	}
	return nil
}

var safeInterface = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9.:/-]*$`)

// ValidateInterface rejects names unsafe for an interface command.
func ValidateInterface(value string) error {
	if !safeInterface.MatchString(value) {
		return ErrInvalid
	}
	return nil
}

// FormatDescription renders and validates a neighbor-derived description.
func FormatDescription(peer Neighbor, opts FormatOptions) (string, error) {
	port := peer.NeighborInterface
	if !opts.FullInterfaceNames {
		port = ShortInterface(port, opts.Lowercase)
	} else if opts.Lowercase {
		port = strings.ToLower(port)
	}
	v := "To_" + strings.ReplaceAll(peer.NeighborName, " ", "_") + "_" + strings.ReplaceAll(port, " ", "_")
	return v, ValidateDescription(v)
}

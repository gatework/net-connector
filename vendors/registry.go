// Package vendors exposes the immutable catalog of supported network device
// platforms. Platform behavior lives in family-scoped internal packages.
package vendors

import (
	"fmt"
	"maps"
	"slices"
	"sync"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/vendors/centec"
	"github.com/gatework/net-connector/vendors/cisco"
	"github.com/gatework/net-connector/vendors/fortinet"
	"github.com/gatework/net-connector/vendors/h3c"
	"github.com/gatework/net-connector/vendors/hillstone"
	"github.com/gatework/net-connector/vendors/huawei"
	"github.com/gatework/net-connector/vendors/juniper"
	"github.com/gatework/net-connector/vendors/paloalto"
	"github.com/gatework/net-connector/vendors/radware"
	"github.com/gatework/net-connector/vendors/topsec"
)

// Registry is an immutable catalog of supported CLI platforms.
type Registry struct {
	entries        map[string]platform.Platform
	inventoryOrder []platform.Platform
}

// NewBuiltinRegistry returns the process-wide immutable catalog. Platforms
// return detached terminal copies, so callers may customize them safely.
func NewBuiltinRegistry() *Registry { return builtinRegistry() }

var builtinRegistry = sync.OnceValue(func() *Registry {
	// This order preserves the former fleet first-match behavior for
	// identities that satisfy more than one vendor rule. The lookup map is
	// derived from the same declarations so canonical keys cannot drift.
	ordered := []platform.Platform{
		h3c.Wireless(), h3c.New(), cisco.NXOS(), cisco.IOS(), radware.New(),
		paloalto.New(), huawei.New(), hillstone.New(), centec.New(), topsec.New(),
		fortinet.New(), juniper.New(),
	}
	entries := make(map[string]platform.Platform, len(ordered))
	for _, platform := range ordered {
		name := platform.Name()
		if name == "" {
			panic("vendors: platform has an empty name")
		}
		if _, exists := entries[name]; exists {
			panic("vendors: duplicate platform name: " + name)
		}
		entries[name] = platform
	}
	return &Registry{entries: entries, inventoryOrder: ordered}
})

// Names returns a sorted, detached list of canonical platform keys.
func (r *Registry) Names() []string {
	if r == nil {
		return nil
	}
	return slices.Sorted(maps.Keys(r.entries))
}

// Lookup returns the immutable platform object registered for name.
func (r *Registry) Lookup(name string) (platform.Platform, error) {
	if r != nil {
		if d, ok := r.entries[name]; ok {
			return d, nil
		}
	}
	return nil, fmt.Errorf("vendors: unknown vendor: %w", connector.ErrUnsupported)
}

// ResolvePlatform applies built-in vendor, OS and model recognition. User
// overrides are applied by fleet before this fallback is consulted.
func (r *Registry) ResolvePlatform(identity platform.Identity) (string, bool) {
	if r == nil {
		return "", false
	}
	identity = identity.Normalized()
	for _, platform := range r.inventoryOrder {
		if platform.MatchInventory(identity) {
			return platform.Name(), true
		}
	}
	return "", false
}

package driver

import (
	"fmt"
	"slices"

	"github.com/gatework/netops/device"
)

// Registry is an ordered, immutable platform catalog. Its order is the
// classification priority: the first platform whose Classifier matches an
// identity wins. It implements netops inventory.Classifier.
type Registry struct {
	order []Driver
	byKey map[string]Driver
}

// NewRegistry builds a registry; keys must be unique and non-empty.
func NewRegistry(ds ...Driver) (*Registry, error) {
	r := &Registry{byKey: make(map[string]Driver, len(ds))}
	for _, d := range ds {
		k := d.Platform()
		if k == "" {
			return nil, fmt.Errorf("driver: platform without a key")
		}
		if _, dup := r.byKey[k]; dup {
			return nil, fmt.Errorf("driver: duplicate platform %s", k)
		}
		r.byKey[k] = d
		r.order = append(r.order, d)
	}
	return r, nil
}

// Lookup returns the platform with key.
func (r *Registry) Lookup(key string) (Driver, error) {
	d, ok := r.byKey[key]
	if !ok {
		return nil, fmt.Errorf("%w: platform %q", ErrUnsupported, key)
	}
	return d, nil
}

// Platforms returns the keys in classification order.
func (r *Registry) Platforms() []string {
	out := make([]string, len(r.order))
	for i, d := range r.order {
		out[i] = d.Platform()
	}
	return out
}

// Classify returns the first platform whose Classifier matches id.
func (r *Registry) Classify(id device.Identity) (string, bool) {
	n := id.Normalized()
	i := slices.IndexFunc(r.order, func(d Driver) bool {
		c, ok := As[Classifier](d)
		return ok && c.Match(n)
	})
	if i < 0 {
		return "", false
	}
	return r.order[i].Platform(), true
}

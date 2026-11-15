// Package platform contains the leaf contracts shared by vendor drivers and
// the packages that consume them: the Platform and Registry interfaces,
// inventory identity and diagnostic errors. Capability interfaces and their
// data types belong to the consuming packages (topology, transfer).
package platform

import (
	"errors"
	"fmt"
	"regexp"
	"strings"

	"github.com/gatework/net-connector/connector"
)

var (
	// ErrUnsupported reports a platform behavior that is not available.
	ErrUnsupported = errors.New("platform: unsupported behavior")
	// ErrParse reports output that the platform cannot recognize.
	ErrParse = errors.New("platform: unrecognized output")
)

// DiagnosticError carries stable machine-readable failure metadata across a
// vendor-policy boundary without importing a workflow package.
type DiagnosticError struct {
	Code, Phase string
	Cause       error
}

func (e *DiagnosticError) Error() string {
	if e == nil {
		return "platform: diagnostic unavailable"
	}
	return fmt.Sprintf("platform: %s (%s)", e.Code, e.Phase)
}
func (e *DiagnosticError) Unwrap() error {
	if e == nil {
		return nil
	}
	return e.Cause
}

// DiagnosticCode returns the stable failure code without formatting its cause.
func (e *DiagnosticError) DiagnosticCode() string {
	if e == nil {
		return ""
	}
	return e.Code
}

// DiagnosticPhase returns the operation phase without formatting its cause.
func (e *DiagnosticError) DiagnosticPhase() string {
	if e == nil {
		return ""
	}
	return e.Phase
}

// DiagnosticMetadata lets consumers preserve structured errors while keeping
// the shared platform package independent of business workflows.
//
//nolint:iface // shared contract: topology and workflow classify errors through it
type DiagnosticMetadata interface {
	error
	DiagnosticCode() string
	DiagnosticPhase() string
}

// NewDiagnosticError attaches safe failure metadata while retaining the cause for unwrapping.
func NewDiagnosticError(code, phase string, cause error) error {
	return &DiagnosticError{Code: code, Phase: phase, Cause: cause}
}

// Platform is one authoritative CLI platform: a device driver with a
// canonical key and an inventory matcher. Optional business capabilities are
// interfaces defined by the packages that consume them.
type Platform interface {
	connector.Driver
	Name() string
	// MatchInventory classifies a normalized inventory identity.
	MatchInventory(identity Identity) bool
}

// Registry resolves immutable platform objects by their canonical platform key.
//
//nolint:iface // shared contract consumed by fleet, topology, transfer and workflow
type Registry interface {
	Names() []string
	Lookup(name string) (Platform, error)
}

// Identity contains the vendor, operating system and model reported
// by an inventory source. Built-in registries normalize these values before
// asking platform matchers to classify them.
type Identity struct {
	Vendor, OS, Model string
}

var identitySeparators = regexp.MustCompile(`[^a-z0-9]+`)

// NormalizeLabel lowercases an inventory label and collapses every run of
// other characters into one space, so "H3C-Comware" and "h3c comware" match.
func NormalizeLabel(value string) string {
	return strings.TrimSpace(identitySeparators.ReplaceAllString(strings.ToLower(value), " "))
}

// Normalized returns the identity with every label normalized.
func (i Identity) Normalized() Identity {
	return Identity{Vendor: NormalizeLabel(i.Vendor), OS: NormalizeLabel(i.OS), Model: NormalizeLabel(i.Model)}
}

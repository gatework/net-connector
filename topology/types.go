// Package topology discovers neighbors and safely plans interface descriptions.
package topology

import (
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strings"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/platform"
)

// Topology failure categories.
var (
	ErrInvalid      = errors.New("topology: invalid plan")
	ErrUnsupported  = errors.New("topology: unsupported operation")
	ErrParse        = platform.ErrParse
	ErrStale        = errors.New("topology: stale plan")
	ErrConfirmation = errors.New("topology: confirmation required")
	ErrVerification = errors.New("topology: description unconfirmed")
	ErrPersistence  = errors.New("topology: persistence unconfirmed")
)

// Error formats metadata only; response bodies are never included in diagnostics.
type Error struct {
	Code, Phase string
	cause       error
}

func (e *Error) Error() string { return "topology: " + e.Code + " (" + e.Phase + ")" }

// GoString formats safe diagnostic metadata without device responses.
func (e *Error) GoString() string                    { return e.Error() }
func (e *Error) Unwrap() error                       { return e.cause }
func newError(code, phase string, cause error) error { return &Error{code, phase, cause} }

// Neighbor is a vendor-neutral discovered adjacency.
type Neighbor struct {
	LocalInterface    string `json:"local_interface"`
	NeighborName      string `json:"neighbor_name"`
	NeighborInterface string `json:"neighbor_interface"`
	ChassisID         string `json:"chassis_id"`
	Protocol          string `json:"protocol"`
}

var unknownNeighbor = regexp.MustCompile(`(?i)^(?:-+|n/?a|unknown|none|null|not\s+(?:available|advertised))?$`)

// IdentityIssue reports which advertised neighbor identity is unknown.
func (n Neighbor) IdentityIssue() string {
	if unknownNeighbor.MatchString(strings.TrimSpace(n.NeighborName)) {
		return "unknown_neighbor_name"
	}
	if unknownNeighbor.MatchString(strings.TrimSpace(n.NeighborInterface)) {
		return "unknown_neighbor_interface"
	}
	return ""
}

// WriteMode describes the mode transitions around a platform's interface
// description commands.
type WriteMode struct{ Enter, Leave, InterfaceExit string }

// Change binds one proposed description to its prior value and neighbor.
type Change struct {
	Interface      string   `json:"interface"`
	OldDescription string   `json:"old_description"`
	NewDescription string   `json:"new_description"`
	Neighbor       Neighbor `json:"neighbor"`
}

// Evidence holds neighbor name, neighbor port and the prior description.
type Evidence [3]string

// Plan contains exact, ordered change, verification, and persistence commands.
// Apply snapshots and validates all fields before performing any device I/O.
type Plan struct {
	Host     string                 `json:"host"`
	Platform string                 `json:"platform"`
	Evidence map[string]Evidence    `json:"evidence"`
	Changes  []Change               `json:"changes"`
	Commands []string               `json:"commands"`
	Scope    string                 `json:"scope"`
	Receipts []connector.StepResult `json:"receipts,omitempty"`
}

// Comparison records one interface description comparison and its evidence status.
type Comparison struct {
	Interface string  `json:"interface"`
	Neighbor  string  `json:"neighbor"`
	Port      string  `json:"port"`
	Current   *string `json:"current"`
	Expected  *string `json:"expected"`
	Status    string  `json:"status"`
	Reason    string  `json:"reason,omitempty"`
}

// Issue identifies evidence that prevents an interface conclusion.
type Issue struct {
	Interface string `json:"interface"`
	Code      string `json:"code"`
}

// Audit contains comparisons, evidence issues and an optional verified-interface plan.
type Audit struct {
	Plan           *Plan                  `json:"plan"`
	Comparisons    []Comparison           `json:"comparisons"`
	Issues         []Issue                `json:"issues"`
	ManualRequired bool                   `json:"manual_required"`
	Receipts       []connector.StepResult `json:"receipts,omitempty"`
}

// Complete reports whether the audit has no evidence issues.
func (a Audit) Complete() bool { return len(a.Issues) == 0 }

// Changes counts verified comparisons whose descriptions differ.
func (a Audit) Changes() int {
	n := 0
	for _, c := range a.Comparisons {
		if c.Status != "matches" && c.Status != "unverified" {
			n++
		}
	}
	return n
}

// FormatOptions defaults to abbreviated port names. Callbacks run synchronously
// inside the device operation lease and must honor their caller's cancellation.
type FormatOptions struct {
	FullInterfaceNames bool
	Lowercase          bool
	Formatter          func(Neighbor) (string, error)
	DescriptionMatcher func(string, string, Neighbor) bool
}

// ApplyOptions supplies explicit confirmation and execution limits.
type ApplyOptions struct {
	Confirmed bool
	Execute   connector.ExecuteOptions
}

// Snapshot carries discovered topology and the command receipts that produced it.
type Snapshot struct {
	Neighbors    []Neighbor             `json:"neighbors"`
	Descriptions map[string]string      `json:"descriptions"`
	Receipts     []connector.StepResult `json:"receipts"`
}

// Result retains apply receipts and confirmed verification and persistence states.
type Result struct {
	Receipts  []connector.StepResult `json:"receipts"`
	Verified  bool                   `json:"verified"`
	Persisted bool                   `json:"persisted"`
}

// Steps returns a copy of the command receipt slice.
func (r Result) Steps() []connector.StepResult {
	return slices.Clone(r.Receipts)
}
func (r Result) String() string {
	return fmt.Sprintf("topology.Result{steps:%d,verified:%t,persisted:%t}", len(r.Receipts), r.Verified, r.Persisted)
}

// GoString formats apply metadata without raw responses.
func (r Result) GoString() string { return r.String() }

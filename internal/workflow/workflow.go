// Package workflow coordinates concrete operations independently of command parsing.
package workflow

import (
	"context"
	"errors"
	"io"
	"path/filepath"
	"sync"

	"github.com/gatework/net-connector/archive"
	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/fleet"
	"github.com/gatework/net-connector/internal/batchreport"
	"github.com/gatework/net-connector/transfer"
	"github.com/gatework/net-connector/vendors"
)

// ErrInvalidRequest reports an invalid operation or execution budget.
var ErrInvalidRequest = errors.New("workflow: invalid request")

// Runtime contains the application dependencies shared by operation workflows.
// Bootstrap builds it from validated settings and resource factories.
type Runtime struct {
	Rules        *fleet.Rules
	Registry     *vendors.Registry
	Workers      int
	Directory    string
	LogDirectory func(mode, directory string) string
	OpenDevice   DeviceOpener
}

// SessionObserver receives session events for the current workflow operation.
type SessionObserver func(context.Context, connector.SessionEvent) error

// DeviceOpener creates one device session with operation-local logging and observation.
type DeviceOpener func(context.Context, fleet.Record, io.Writer, SessionObserver) (*connector.Device, error)

// TFTPSettings supplies the transfer policy and archive runtime dependencies.
type TFTPSettings struct {
	ArchiveTimeouts   archive.Timeouts
	Policy            *transfer.Policy
	LimitPerPlatform  int
	ArchiveWorkerPath string
	ArchivePassword   func() string
}

// TopologySettings supplies topology collection and description formatting policy.
type TopologySettings struct {
	Mode                 string
	Workers              int
	Limit                int
	Directory            string
	DescriptionFormat    string
	AbbreviatePorts      bool
	LowercasePorts       bool
	NeighborNamePrefixes []string
}

// Result is the outcome of one command: a batch report (or, for plan
// commands, the planned report), or an inventory listing.
type Result struct {
	Success bool
	// Report is the batch report; Planned marks a plan preview without I/O.
	Report  *batchreport.Report
	Planned bool
	// ArchiveDirectories lists the TFTP server archive directories used.
	ArchiveDirectories []string
	// Inventory is the classified inventory for listing commands.
	Inventory []fleet.PlanEntry
}

// Runner executes operations and reports typed events to Observe.
type Runner struct {
	Observe     Observer
	progressMu  sync.Mutex
	progressErr error
}

// RecordFailure marks the batch failed after its report was written, for
// example when progress or output rendering failed, and rewrites report.json.
// Device results and stored artifacts are retained unchanged.
func RecordFailure(ctx context.Context, result *Result, code string, err error) {
	if result == nil || err == nil {
		return
	}
	result.Success = false
	report := result.Report
	if report == nil || result.Planned || report.Directory == "" {
		return
	}
	report.Success = false
	if report.ReportError == "" {
		report.ReportError = code
	}
	_ = writeJSON(context.WithoutCancel(ctx), filepath.Join(report.Directory, "report.json"), report)
}

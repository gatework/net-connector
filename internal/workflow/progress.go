package workflow

import (
	"context"
	"time"

	"github.com/gatework/net-connector/archive"
	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/internal/batchreport"
)

// Event carries bounded operation facts, never terminal text or response bodies.
// Observe calls are serialized, and an observer error is retained until the
// operation's final report. A failed display never causes a device write replay.
type Event interface{ workflowEvent() }

// Observer receives serialized progress events and may report an output failure.
type Observer func(Event) error

// PlanEvent describes the selected inventory and worker budget.
type PlanEvent struct {
	Total, Selected, Workers int
	Mode                     string
}

// StartEvent identifies a device that began execution.
type StartEvent struct{ Host, Platform string }

// SessionEvent carries safe connector lifecycle metadata.
type SessionEvent connector.SessionEvent

// OutcomeEvent records a device result and retained source evidence.
type OutcomeEvent struct {
	Host, ErrorCode                 string
	Status                          batchreport.Status
	Outcome                         batchreport.Outcome
	Duration                        time.Duration
	TextWarningBytes                int
	SourceCommitted, SourceVerified bool
}

// TransferStageEvent identifies the current transfer phase for a device.
type TransferStageEvent struct{ Host, Stage string }

// Phase identifies a workflow preparation or execution phase.
type Phase string

// Workflow phases reported through PhaseEvent.
const (
	PhaseArchivePreflight Phase = "archive_preflight"
	PhaseTransfer         Phase = "transfer"
	PhaseTopologyPlan     Phase = "topology_plan"
	PhaseTopologyApply    Phase = "topology_apply"
)

// PhaseEvent reports a workflow phase and its time budget.
type PhaseEvent struct {
	Phase   Phase
	Timeout time.Duration
}

// ArchivePreflightEvent reports archive preparation progress for one target group.
type ArchivePreflightEvent struct {
	Progress      archive.PrepareProgress
	Group, Groups int
}

// ArchiveReadyEvent identifies an archive destination that passed preparation.
type ArchiveReadyEvent struct{ Server, Directory string }

// BeginPhaseEvent reports the start of a new bounded device round.
type BeginPhaseEvent struct{ Total, Workers int }

// FinishedEvent marks completion of workflow progress reporting.
type FinishedEvent struct{}

func (PlanEvent) workflowEvent()             {}
func (StartEvent) workflowEvent()            {}
func (SessionEvent) workflowEvent()          {}
func (OutcomeEvent) workflowEvent()          {}
func (TransferStageEvent) workflowEvent()    {}
func (PhaseEvent) workflowEvent()            {}
func (ArchivePreflightEvent) workflowEvent() {}
func (ArchiveReadyEvent) workflowEvent()     {}
func (BeginPhaseEvent) workflowEvent()       {}
func (FinishedEvent) workflowEvent()         {}

func (r *Runner) emit(event Event) error {
	if r.Observe == nil {
		return nil
	}
	r.progressMu.Lock()
	defer r.progressMu.Unlock()
	err := r.Observe(event)
	if err != nil && r.progressErr == nil {
		r.progressErr = err
	}
	return err
}
func (r *Runner) observe() SessionObserver {
	return func(_ context.Context, e connector.SessionEvent) error {
		_ = r.emit(SessionEvent(e))
		return nil
	}
}
func (r *Runner) begin() {
	r.progressMu.Lock()
	r.progressErr = nil
	r.progressMu.Unlock()
}

// finish emits the final event; a progress failure fails the batch while
// keeping every device result.
func (r *Runner) finish(report *batchreport.Report) {
	_ = r.emit(FinishedEvent{})
	r.progressMu.Lock()
	err := r.progressErr
	r.progressMu.Unlock()
	if err != nil {
		result := Result{Report: report}
		RecordFailure(context.Background(), &result, "progress_failed", err)
	}
}

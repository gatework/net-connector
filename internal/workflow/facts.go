package workflow

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/gatework/net-connector/facts"
	"github.com/gatework/net-connector/fleet"
	"github.com/gatework/net-connector/internal/batchreport"
	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/storage"
)

// FactsStage collects what a device reports about itself with the platform's
// read-only commands and compares it with the inventory.
type FactsStage struct{}

// Name returns the stable stage identifier recorded in reports.
func (FactsStage) Name() string { return "facts" }

// Admit refuses a platform that declares no fact commands, or whose fact
// commands it does not itself classify as read-only, before any connection.
func (FactsStage) Admit(_ fleet.Record, p platform.Platform) batchreport.Status {
	if _, err := facts.Commands(p); err != nil {
		if errors.Is(err, facts.ErrNotReadOnly) {
			return batchreport.StatusNotReadOnly
		}
		return batchreport.StatusUnsupportedOperation
	}
	return ""
}

// Run executes the stage and retains its evidence even on failure.
func (FactsStage) Run(ctx context.Context, s *Session, e *Evidence) error {
	device, err := s.Device(ctx)
	if err != nil {
		return err
	}
	found, _, err := facts.Collect(ctx, device, s.Platform)
	if err != nil {
		return err
	}
	artifact := &batchreport.Facts{
		Hostname: found.Hostname, Model: found.Model, Serial: found.Serial, OSVersion: found.OSVersion, Uptime: found.Uptime,
		Mismatches: inventoryMismatches(s.Record, found),
	}
	e.Artifacts.Facts = artifact
	if len(artifact.Mismatches) > 0 {
		e.Outcome = batchreport.OutcomeMismatch
		e.MarkReview()
	}
	return nil
}

// inventoryMismatches names the inventory fields that disagree with the
// device. A field either side leaves empty is not compared. Model and version
// labels differ in decoration between sources ("Cisco WS-C3750G" and
// "WS-C3750G"), so they match when one normalized label contains the other.
func inventoryMismatches(record fleet.Record, found facts.Facts) []string {
	mismatches := []string{}
	contains := func(inventory, device string) bool {
		a, b := platform.NormalizeLabel(inventory), platform.NormalizeLabel(device)
		return a == "" || b == "" || strings.Contains(a, b) || strings.Contains(b, a)
	}
	if !contains(record.Model, found.Model) {
		mismatches = append(mismatches, "model")
	}
	if record.Serial != "" && found.Serial != "" && !strings.EqualFold(strings.TrimSpace(record.Serial), found.Serial) {
		mismatches = append(mismatches, "serial")
	}
	if !contains(record.OSVersion, found.OSVersion) {
		mismatches = append(mismatches, "os_version")
	}
	return mismatches
}

// FactsOptions controls device fact collection.
type FactsOptions struct {
	// LimitPerPlatform samples at most this many devices per platform; zero runs all.
	LimitPerPlatform  int
	Plan              bool
	Directory, Policy string
}

// Facts collects device facts from every capable planned device and reports
// the inventory fields that disagree with them.
func (r *Runner) Facts(ctx context.Context, runtime Runtime, rows []inventory.Device, o FactsOptions) (Result, error) {
	op := Operation{Name: "facts", Outcome: batchreport.OutcomeCollected, Stages: []Stage{FactsStage{}}, Tolerate: []batchreport.Status{batchreport.StatusUnsupportedOperation}}
	plan, err := planFor(runtime, rows, op, fleet.PlanOptions{LimitPerPlatform: o.LimitPerPlatform})
	if err != nil {
		return Result{}, err
	}
	if o.Plan {
		report := r.Plan(runtime, plan, op, o.Policy)
		return Result{Success: report.Success, Report: &report, Planned: true}, nil
	}
	directory, err := storage.CreateBatchDirectory(o.Directory, time.Now())
	if err != nil {
		return Result{}, err
	}
	return r.run(ctx, runtime, plan, op, ExecuteOptions{Directory: directory, Policy: o.Policy}, nil)
}

package workflow

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/gatework/net-connector/archive"
	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/fleet"
	"github.com/gatework/net-connector/internal/batchreport"
	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/storage"
	"github.com/gatework/net-connector/transfer"
	"github.com/gatework/net-connector/vendors"
)

// fakeStage runs fn without opening a device.
type fakeStage struct {
	name string
	skip batchreport.Status
	fn   func(ctx context.Context, s *Session, e *Evidence) error
}

func (f fakeStage) Name() string                                             { return f.name }
func (f fakeStage) Admit(fleet.Record, platform.Platform) batchreport.Status { return f.skip }
func (f fakeStage) Run(ctx context.Context, s *Session, e *Evidence) error {
	if f.fn == nil {
		return nil
	}
	return f.fn(ctx, s, e)
}

func testRuntime(t *testing.T) Runtime {
	t.Helper()
	registry := vendors.NewBuiltinRegistry()
	rules, err := fleet.NewRules(fleet.RuleOptions{}, registry)
	if err != nil {
		t.Fatal(err)
	}
	return Runtime{Rules: rules, Registry: registry, Workers: 1}
}

func testPlan(t *testing.T, runtime Runtime, mode string, rows ...inventory.Device) fleet.Plan {
	t.Helper()
	options := fleet.PlanOptions{}
	if mode == "tftp" {
		options.Target = func(fleet.Record) (transfer.Target, error) {
			return transfer.Target{TFTPOptions: transfer.TFTPOptions{Server: "192.0.2.50", Path: "running.cfg"}}, nil
		}
	}
	plan, err := fleet.NewPlan(rows, runtime.Rules, options)
	if err != nil {
		t.Fatal(err)
	}
	return plan
}

func readReport(t *testing.T, directory string) batchreport.Report {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(directory, "report.json"))
	if err != nil {
		t.Fatal(err)
	}
	var report batchreport.Report
	if err = json.Unmarshal(data, &report); err != nil {
		t.Fatal(err)
	}
	return report
}

func TestPipelineStopsAtFirstFailedStageAndKeepsEvidence(t *testing.T) {
	runtime := testRuntime(t)
	plan := testPlan(t, runtime, "backup", inventory.Device{IP: "192.0.2.1", Vendor: "h3c"})
	ran := []string{}
	op := Operation{Name: "test", Outcome: "done", Stages: []Stage{
		fakeStage{name: "first", fn: func(_ context.Context, _ *Session, e *Evidence) error {
			ran = append(ran, "first")
			e.Artifacts.Save = &batchreport.Save{Confirmed: true}
			e.MarkPartial()
			return nil
		}},
		fakeStage{name: "second", fn: func(context.Context, *Session, *Evidence) error {
			ran = append(ran, "second")
			return &connector.Error{Code: "device_error", Phase: "command"}
		}},
		fakeStage{name: "third", fn: func(context.Context, *Session, *Evidence) error { ran = append(ran, "third"); return nil }},
	}}
	directory := t.TempDir()
	report, err := (&Runner{}).Execute(t.Context(), runtime, plan, op, ExecuteOptions{Directory: directory, Policy: "selected"})
	if err != nil || report.Success {
		t.Fatal(err, report)
	}
	d := report.Devices[0]
	if strings.Join(ran, ",") != "first,second" || d.Status != batchreport.StatusPartial || d.FailedStage != "second" || d.Diagnostic.Code != "device_error" || d.Diagnostic.Phase != "command" || !d.Artifacts.Save.Confirmed {
		t.Fatalf("pipeline did not stop with evidence: %v %+v", ran, d)
	}
	if got := []string{d.Stages[0].Status, d.Stages[1].Status, d.Stages[2].Status}; strings.Join(got, ",") != "succeeded,failed,skipped" {
		t.Fatal(got)
	}
	if persisted := readReport(t, directory); persisted.Devices[0].FailedStage != "second" || persisted.SchemaVersion != batchreport.SchemaVersion {
		t.Fatalf("report.json differs: %+v", persisted)
	}
	if _, err := os.Stat(filepath.Join(directory, "events.jsonl")); err != nil {
		t.Fatal(err)
	}
}

func TestPipelineAuthenticationFailureIsItsOwnStage(t *testing.T) {
	runtime := testRuntime(t)
	runtime.OpenDevice = func(context.Context, fleet.Record, io.Writer, SessionObserver) (*connector.Device, error) {
		return nil, fleet.ErrMissingCredentials
	}
	plan := testPlan(t, runtime, "backup", inventory.Device{IP: "192.0.2.1", Vendor: "h3c"})
	op := Operation{Name: "test", Stages: []Stage{
		fakeStage{name: "work", fn: func(ctx context.Context, s *Session, _ *Evidence) error { _, err := s.Device(ctx); return err }},
		fakeStage{name: "after"},
	}}
	report, _ := (&Runner{}).Execute(t.Context(), runtime, plan, op, ExecuteOptions{Directory: t.TempDir(), Policy: "selected"})
	d := report.Devices[0]
	if d.Status != batchreport.StatusFailed || d.FailedStage != "authenticate" || d.Diagnostic.Code != "missing_credentials" {
		t.Fatalf("authentication not reported: %+v", d)
	}
	var got []string
	for _, s := range d.Stages {
		got = append(got, s.Name+":"+s.Status)
	}
	if strings.Join(got, ",") != "authenticate:failed,work:skipped,after:skipped" {
		t.Fatal(got)
	}
}

func TestPipelinePolicies(t *testing.T) {
	runtime := testRuntime(t)
	rows := []inventory.Device{{IP: "192.0.2.1", Vendor: "h3c"}, {IP: "192.0.2.2", Vendor: "unknown-vendor"}}
	for _, tc := range []struct {
		name, policy string
		rows         []inventory.Device
		verified     bool
		want         bool
	}{
		{"selected ignores nothing unexpected", "selected", rows[:1], false, true},
		{"selected fails on an unsupported vendor", "selected", rows, false, false},
		{"strict requires every entry", "strict", rows, false, false},
		{"strict passes when all succeed", "strict", rows[:1], false, true},
		{"verified requires verification evidence", "verified", rows[:1], false, false},
		{"verified passes with evidence", "verified", rows[:1], true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			plan := testPlan(t, runtime, "backup", tc.rows...)
			op := Operation{Name: "test", Stages: []Stage{fakeStage{name: "work", fn: func(_ context.Context, _ *Session, e *Evidence) error {
				e.Verified = tc.verified
				return nil
			}}}}
			report, err := (&Runner{}).Execute(t.Context(), runtime, plan, op, ExecuteOptions{Directory: t.TempDir(), Policy: tc.policy})
			if err != nil || report.Success != tc.want {
				t.Fatalf("success=%t want %t: %v %+v", report.Success, tc.want, err, report.Counts)
			}
		})
	}
}

func TestPipelineCancellationLeavesUnstartedDevicesNotStarted(t *testing.T) {
	runtime := testRuntime(t)
	plan := testPlan(t, runtime, "backup", inventory.Device{IP: "192.0.2.1", Vendor: "h3c"}, inventory.Device{IP: "192.0.2.2", Vendor: "h3c"})
	ctx, cancel := context.WithCancel(t.Context())
	var started atomic.Int32
	op := Operation{Name: "test", Stages: []Stage{fakeStage{name: "work", fn: func(ctx context.Context, _ *Session, _ *Evidence) error {
		started.Add(1)
		cancel()
		<-ctx.Done()
		return ctx.Err()
	}}}}
	report, err := (&Runner{}).Execute(ctx, runtime, plan, op, ExecuteOptions{Directory: t.TempDir(), Policy: "selected"})
	if err != nil || started.Load() != 1 || !report.Interrupted || report.Status != batchreport.BatchInterrupted {
		t.Fatalf("started=%d err=%v %+v", started.Load(), err, report)
	}
	if report.Devices[0].Status != batchreport.StatusInterrupted || report.Devices[1].Status != batchreport.StatusNotStarted {
		t.Fatalf("statuses: %s %s", report.Devices[0].Status, report.Devices[1].Status)
	}
}

func TestPipelinePlanPerformsNoIO(t *testing.T) {
	runtime := testRuntime(t)
	plan := testPlan(t, runtime, "backup", inventory.Device{IP: "192.0.2.1", Vendor: "h3c", Name: "edge"}, inventory.Device{IP: "192.0.2.2", Vendor: "h3c"})
	op := Operation{Name: "test", Stages: []Stage{
		BackupStage{},
		fakeStage{name: "gate", skip: "", fn: func(context.Context, *Session, *Evidence) error { t.Fatal("plan ran a stage"); return nil }},
	}}
	report := (&Runner{}).Plan(runtime, plan, op, "selected")
	if report.Status != "planned" || report.Devices[0].Target.File != "edge-192.0.2.1.txt" || report.Devices[1].Target.File != "unnamed-192.0.2.2.txt" {
		t.Fatalf("plan: %+v", report)
	}
}

func TestClassifyKeepsPrimaryAcrossCleanup(t *testing.T) {
	primary := &connector.Error{Code: "command_timeout", Phase: "command"}
	cleanup := &storage.WriteError{Cause: errors.New("PRIVATE")}
	got := classify(errors.Join(primary, cleanup), "execute")
	if got.Code != "command_timeout" || got.Phase != "command" {
		t.Fatal(got)
	}
	got = classify(&storage.WriteError{Receipt: storage.Receipt{State: storage.StateCommitted}, Cause: errors.New("PRIVATE")}, "backup")
	if got.Code != "file_persistence_unconfirmed" || got.Phase != "backup" {
		t.Fatal(got)
	}
	if got = classify(errors.New("PRIVATE"), "save"); got.Code != "internal_error" || strings.Contains(got.Code+got.Phase, "PRIVATE") {
		t.Fatal(got)
	}
}

// archiveStage uploads through a real local archive pool without a device, so
// the report and export contract are exercised end to end.
type archiveStage struct {
	pool *archive.Pool
	root string
}

func (archiveStage) Name() string                                             { return "tftp" }
func (archiveStage) Admit(fleet.Record, platform.Platform) batchreport.Status { return "" }
func (a archiveStage) Run(ctx context.Context, _ *Session, e *Evidence) error {
	result, err := a.pool.Upload(ctx, "running.cfg", "device.cfg", func(_ context.Context, name string) (transfer.Receipt, error) {
		err := os.WriteFile(filepath.Join(a.root, name), []byte("中文配置\n"), 0o600)
		return transfer.Receipt{Server: "192.0.2.50", Path: name, Verification: transfer.VerificationDeviceReported}, err
	})
	e.Artifacts.Transfer, e.Artifacts.Archive = reportTransfer(result.Transfer), reportArchive(result.Receipt)
	e.MarkPartial()
	if result.Receipt.Verified() {
		e.Verified = true
		e.Artifacts.Transfer.Verification = "server_verified"
	}
	return err
}

func TestArchiveUploadReportAndExport(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	pool, err := archive.NewPool(archive.PoolOptions{Root: root, Directory: directory, Parallel: 1})
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	if err = pool.Prepare(t.Context(), nil); err != nil {
		t.Fatal(err)
	}
	runtime := testRuntime(t)
	plan := testPlan(t, runtime, "tftp", inventory.Device{IP: "192.0.2.1", Vendor: "h3c"})
	op := Operation{Name: "tftp", Outcome: "uploaded", Stages: []Stage{archiveStage{pool: pool, root: root}}}
	report, err := (&Runner{}).Execute(t.Context(), runtime, plan, op, ExecuteOptions{Directory: directory, Policy: "verified"})
	if err != nil || !report.Success {
		t.Fatal(err, report)
	}
	row := readReport(t, directory).Devices[0]
	if !row.Verified || row.Artifacts.Transfer.Verification != "server_verified" || row.Artifacts.Archive.Cleanup != "complete" {
		t.Fatalf("archive evidence: %+v", row.Artifacts)
	}
	moved := filepath.Join(t.TempDir(), "moved")
	if err = os.Rename(directory, moved); err != nil {
		t.Fatal(err)
	}
	body, artifact, err := storage.ReadBatchSaved(t.Context(), moved, "192.0.2.1")
	if err != nil || string(body) != "中文配置\n" || artifact.Path != filepath.Join(moved, "tftp", "device.cfg") {
		t.Fatal(string(body), artifact, err)
	}
	_, receipt, err := storage.ExportBatchSaved(t.Context(), moved, "192.0.2.1", filepath.Join(t.TempDir(), "export.cfg"))
	if err != nil || !receipt.Durable() {
		t.Fatal(receipt, err)
	}
}

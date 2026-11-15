package workflow

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gatework/net-connector/internal/batchreport"
	"github.com/gatework/net-connector/parallel"
)

// pipelineRun owns the journal and per-device evidence for one Execute call.
type pipelineRun struct {
	runner     *Runner
	runtime    Runtime
	op         Operation
	options    ExecuteOptions
	tasks      []pipelineTask
	report     *batchreport.Report
	evidence   []*Evidence
	journal    *os.File
	journalMu  sync.Mutex
	journalErr error
	failures   atomic.Int64
}

func (p *pipelineRun) record(row batchreport.Device) {
	p.journalMu.Lock()
	if e := json.NewEncoder(p.journal).Encode(row); e != nil && p.journalErr == nil {
		p.journalErr = e
	}
	p.journalMu.Unlock()
	event := OutcomeEvent{Host: row.Host, Status: row.Status, Outcome: row.Outcome, ErrorCode: diagnosticCode(row.Diagnostic), Duration: time.Duration(row.DurationMS * float64(time.Millisecond)), TextWarningBytes: textWarningBytes(row)}
	if b := row.Artifacts.Backup; b != nil {
		event.SourceCommitted, event.SourceVerified = b.Saved, b.Complete
	}
	_ = p.runner.emit(event)
}

func (p *pipelineRun) round(ctx context.Context, stages []Stage, admitted func(i int) bool) error {
	r, runtime, tasks, report, evidence, o := p.runner, p.runtime, p.tasks, p.report, p.evidence, p.options
	order := make([]int, 0, len(tasks))
	for i := range tasks {
		if admitted(i) {
			order = append(order, i)
		}
	}
	results, err := parallel.Map(ctx, runtime.Workers, order, func(ctx context.Context, i int) (batchreport.Device, error) {
		t := tasks[i]
		row := report.Devices[t.entry]
		if o.StopAfterFailures > 0 && p.failures.Load() >= int64(o.StopAfterFailures) {
			row.Status = batchreport.StatusStopped
			return row, nil
		}
		if evidence[i] == nil {
			evidence[i] = &Evidence{}
		}
		row = r.runDevice(ctx, runtime, p.op, stages, t.task, row, evidence[i], report.SessionLogs)
		if row.Status == batchreport.StatusFailed || row.Status == batchreport.StatusInterrupted {
			p.failures.Add(1)
		}
		p.record(row)
		return row, nil
	})
	for k, i := range order {
		switch {
		case k >= len(results) || !results[k].Started:
		case results[k].Err == nil:
			report.Devices[tasks[i].entry] = results[k].Value
		default:
			// The worker exited without returning (for example a callback
			// called runtime.Goexit): the device started, so it failed.
			row := report.Devices[tasks[i].entry]
			row.Status, row.FailedStage = batchreport.StatusFailed, "worker"
			row.Diagnostic = &batchreport.Diagnostic{Code: "internal_error", Phase: "worker"}
			report.Devices[tasks[i].entry] = row
		}
	}
	if errors.Is(err, parallel.ErrWorkerExit) {
		report.ReportError = "worker_exited"
		return nil
	}
	return err
}

func (p *pipelineRun) nextRound(ctx context.Context) error {
	r, runtime, tasks, report, evidence, op := p.runner, p.runtime, p.tasks, p.report, p.evidence, p.op
	var runErr error
	if then := op.Then; then != nil && ctx.Err() == nil {
		rows := make([]batchreport.Device, len(tasks))
		for i, t := range tasks {
			rows[i] = report.Devices[t.entry]
			if evidence[i] == nil {
				evidence[i] = &Evidence{}
			}
		}
		if then.Before != nil {
			if err := then.Before(context.WithoutCancel(ctx), rows, evidence); err != nil {
				report.ReportError = "review_write_failed"
				runErr = err
			}
		}
		if runErr == nil {
			_ = r.emit(BeginPhaseEvent{Total: len(tasks), Workers: runtime.Workers})
			runErr = p.round(ctx, then.Stages, func(i int) bool {
				row := report.Devices[tasks[i].entry]
				return row.Status != batchreport.StatusFailed && row.Status != batchreport.StatusInterrupted && then.Admit(row, evidence[i])
			})
		}
		for i, t := range tasks {
			if e := evidence[i]; e != nil && e.Outcome != "" && report.Devices[t.entry].Status == batchreport.StatusSucceeded {
				report.Devices[t.entry].Outcome = e.Outcome
			}
		}
	}
	return runErr
}

func runStages(ctx context.Context, session *Session, stages []Stage, evidence *Evidence, row *batchreport.Device) (failedStage string, failed error) {
	for _, stage := range stages {
		if failed != nil {
			row.Stages = append(row.Stages, batchreport.Stage{Name: stage.Name(), Status: batchreport.StageSkipped})
			continue
		}
		stageStart := time.Now()
		authBefore := session.auth
		err := stage.Run(ctx, session, evidence)
		if authBefore == nil && session.auth != nil {
			row.Stages = append(row.Stages, *session.auth)
			if session.authErr != nil {
				failed, failedStage = session.authErr, "authenticate"
				row.Stages = append(row.Stages, batchreport.Stage{Name: stage.Name(), Status: batchreport.StageSkipped})
				continue
			}
		}
		result := batchreport.Stage{Name: stage.Name(), Status: batchreport.StageSucceeded, DurationMS: milliseconds(time.Since(stageStart))}
		if err != nil {
			diagnostic := classify(err, stage.Name())
			result.Status, result.Diagnostic = batchreport.StageFailed, &diagnostic
			failed, failedStage = err, stage.Name()
		}
		row.Stages = append(row.Stages, result)
	}
	return failedStage, failed
}

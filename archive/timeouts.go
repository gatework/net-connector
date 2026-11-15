package archive

import (
	"context"
	"time"

	"github.com/gatework/net-connector/transfer"
)

const (
	controlTimeout = 10 * time.Second
	// maxStageTimeout is the largest whole-millisecond budget that still
	// leaves room for the control timeout.
	maxStageTimeout = time.Duration(1<<63-1) - controlTimeout - (time.Duration(1<<63-1)-controlTimeout)%time.Millisecond
)

// Timeouts bound separate stages. Zero fields select defaults; negative or
// unrepresentable wire durations are invalid. Filesystem I/O and callbacks must
// cooperate with cancellation; a deadline does not interrupt a blocked fsync.
type Timeouts struct {
	Prepare time.Duration
	Upload  time.Duration
	Verify  time.Duration
	Cleanup time.Duration
}

// DefaultTimeouts is the single definition used by library zero values and
// the application's printed and loaded configuration defaults.
func DefaultTimeouts() Timeouts {
	return Timeouts{Prepare: 240 * time.Second, Upload: transfer.DefaultUploadTimeout, Verify: 100 * time.Second, Cleanup: 10 * time.Second}
}

// Validate checks explicit stage durations without filling absent defaults.
func (t Timeouts) Validate() error {
	if t.Prepare <= 0 || t.Upload <= 0 || t.Verify <= 0 || t.Cleanup <= 0 {
		return ErrArchive
	}
	_, err := t.normalize()
	return err
}

// TimeoutBudget is the v2 wire representation. Every field is a positive
// millisecond count; Go callers normally use Timeouts on ClientOptions.
type TimeoutBudget struct {
	Prepare int64 `json:"prepare_ms"`
	Upload  int64 `json:"upload_ms"`
	Verify  int64 `json:"verify_ms"`
	Cleanup int64 `json:"cleanup_ms"`
}

func (t Timeouts) normalize() (Timeouts, error) {
	d := DefaultTimeouts()
	defaults := [...]time.Duration{d.Prepare, d.Upload, d.Verify, d.Cleanup}
	values := []*time.Duration{&t.Prepare, &t.Upload, &t.Verify, &t.Cleanup}
	for i, value := range values {
		if *value == 0 {
			*value = defaults[i]
		}
		// Keep both millisecond rounding and the control handoff allowance safe.
		if *value < 0 || *value > maxStageTimeout {
			return Timeouts{}, ErrArchive
		}
	}
	return t, nil
}

func milliseconds(d time.Duration) int64 {
	n := int64(d / time.Millisecond)
	if d%time.Millisecond != 0 {
		n++
	}
	return n
}

func (t Timeouts) wire(prepare context.Context) (TimeoutBudget, error) {
	deadline, ok := prepare.Deadline()
	if !ok || prepare.Err() != nil {
		return TimeoutBudget{}, stageFailure("prepare", context.Cause(prepare))
	}
	remaining := time.Until(deadline)
	if remaining <= 0 {
		return TimeoutBudget{}, stageFailure("prepare", context.DeadlineExceeded)
	}
	return TimeoutBudget{milliseconds(remaining), milliseconds(t.Upload), milliseconds(t.Verify), milliseconds(t.Cleanup)}, nil
}
func (w TimeoutBudget) decode() (Timeouts, error) {
	values := []int64{w.Prepare, w.Upload, w.Verify, w.Cleanup}
	for _, value := range values {
		if value <= 0 || value > int64((maxStageTimeout)/time.Millisecond) {
			return Timeouts{}, ErrArchive
		}
	}
	return Timeouts{time.Duration(w.Prepare) * time.Millisecond, time.Duration(w.Upload) * time.Millisecond, time.Duration(w.Verify) * time.Millisecond, time.Duration(w.Cleanup) * time.Millisecond}, nil
}

func stageFailure(phase string, cause error) error {
	if cause == nil {
		cause = ErrArchive
	}
	return &Error{Phase: phase, cause: cause}
}

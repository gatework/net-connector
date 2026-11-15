package workflow

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/gatework/net-connector/archive"
	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/fleet"
	"github.com/gatework/net-connector/internal/batchreport"
	"github.com/gatework/net-connector/internal/textdiff"
	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/storage"
	"github.com/gatework/net-connector/transfer"
	"github.com/gatework/net-connector/vendors"
)

// SaveStage persists the running configuration. Success requires the
// platform's positive save confirmation; a prompt alone is unconfirmed. On a
// commit-model platform the commit is the persistence step, so the stage
// sends nothing.
type SaveStage struct{}

// Name returns the stable stage identifier recorded in reports.
func (SaveStage) Name() string { return "save" }

// Admit checks whether the device and platform support this stage before I/O.
func (SaveStage) Admit(_ fleet.Record, platform platform.Platform) batchreport.Status {
	if _, commits := connector.AsCommitter(platform); !commits && !connector.CanSave(platform) {
		return batchreport.StatusSaveUnsupported
	}
	return ""
}

// Run executes the stage and retains its evidence even on failure.
func (SaveStage) Run(ctx context.Context, s *Session, e *Evidence) error {
	if _, commits := connector.AsCommitter(s.Platform); commits {
		return nil
	}
	device, err := s.Device(ctx)
	if err != nil {
		return err
	}
	_, err = device.SaveConfig(ctx, connector.ExecuteOptions{})
	e.Artifacts.Save = &batchreport.Save{Confirmed: err == nil}
	return err
}

// BackupStage collects the running configuration into "<name>-<IP>.txt".
type BackupStage struct{ Directory string }

// Name returns the stable stage identifier recorded in reports.
func (BackupStage) Name() string { return "backup" }

// Admit checks whether the device and platform support this stage before I/O.
func (BackupStage) Admit(_ fleet.Record, platform platform.Platform) batchreport.Status {
	if !connector.CanCollectConfig(platform) {
		return batchreport.StatusUnsupportedOperation
	}
	return ""
}

// Plan adds the planned stage target without executing device operations.
func (b BackupStage) Plan(task fleet.Task, _ platform.Platform, target *batchreport.Target) {
	target.File, _ = task.Device.Filename()
}

// Run executes the stage and retains its evidence even on failure.
func (b BackupStage) Run(ctx context.Context, s *Session, e *Evidence) error {
	name, err := s.Record.Filename()
	if err != nil {
		return err
	}
	receipt, err := collectConfig(ctx, s, filepath.Join(b.Directory, name))
	return recordBackup(receipt, err, e)
}

// collectConfig collects the device configuration into path. It refuses a
// path that is not a regular file before opening the device.
func collectConfig(ctx context.Context, s *Session, path string) (connector.BackupReceipt, error) {
	if info, statErr := os.Lstat(path); statErr == nil && !info.Mode().IsRegular() {
		return connector.BackupReceipt{}, storage.ErrUnsafe
	} else if statErr != nil && !os.IsNotExist(statErr) {
		return connector.BackupReceipt{}, statErr
	}
	device, err := s.Device(ctx)
	if err != nil {
		return connector.BackupReceipt{}, err
	}
	return device.Backup(ctx, connector.BackupOptions{TextOnly: true, PreserveInvalidEncoding: true, Path: path, RejectSymlink: true, LockTimeout: 5 * time.Second})
}

// recordBackup stores a collected configuration as the device's backup
// artifact. A saved file makes a later failure partial.
func recordBackup(receipt connector.BackupReceipt, err error, e *Evidence) error {
	if receipt.Path != "" {
		e.Artifacts.Backup = reportBackup(receipt)
	}
	if receipt.HasSavedEvidence() {
		e.MarkPartial()
		if err == nil && receipt.HasUnverifiedPair() {
			err = connector.ErrIncomplete
		}
	}
	return err
}

// SnapshotStage collects the configuration around a change. The snapshot
// before the change is saved under "before/" and is the operator's reference
// for a manual rollback; nothing has been written to the device when it
// fails. The snapshot after the change is the batch's backup artifact.
type SnapshotStage struct {
	Directory string
	After     bool
}

// Name returns the stable stage identifier recorded in reports.
func (x SnapshotStage) Name() string {
	if x.After {
		return "snapshot_after"
	}
	return "snapshot_before"
}

// Admit checks whether the device and platform support this stage before I/O.
func (SnapshotStage) Admit(_ fleet.Record, platform platform.Platform) batchreport.Status {
	if !connector.CanCollectConfig(platform) {
		return batchreport.StatusUnsupportedOperation
	}
	return ""
}

// Plan adds the planned stage target without executing device operations.
func (SnapshotStage) Plan(task fleet.Task, _ platform.Platform, target *batchreport.Target) {
	target.File, _ = task.Device.Filename()
}

// Run executes the stage and retains its evidence even on failure.
func (x SnapshotStage) Run(ctx context.Context, s *Session, e *Evidence) error {
	name, err := s.Record.Filename()
	if err != nil {
		return err
	}
	if e.Artifacts.Change == nil {
		e.Artifacts.Change = &batchreport.Change{}
	}
	directory := x.Directory
	if !x.After {
		directory = filepath.Join(x.Directory, "before")
		if err = storage.PrepareDirectory(directory); err != nil {
			return err
		}
	}
	receipt, err := collectConfig(ctx, s, filepath.Join(directory, name))
	snapshot := &batchreport.Snapshot{Path: receipt.Path, Bytes: int64(receipt.Bytes), SHA256: receipt.SHA256}
	if x.After {
		if receipt.HasSavedEvidence() {
			e.Artifacts.Change.After = snapshot
		}
		return recordBackup(receipt, err, e)
	}
	if err == nil && (!receipt.HasSavedEvidence() || receipt.HasUnverifiedPair()) {
		err = connector.ErrIncomplete
	}
	if err == nil {
		e.Artifacts.Change.Before = snapshot
	}
	return err
}

// DiffStage compares the snapshots taken before and after a change and writes
// a unified diff under "diff/" when the configuration changed. It performs no
// device I/O.
type DiffStage struct{ Directory string }

// Name returns the stable stage identifier recorded in reports.
func (DiffStage) Name() string { return "diff" }

// Admit checks whether the device and platform support this stage before I/O.
func (DiffStage) Admit(fleet.Record, platform.Platform) batchreport.Status { return "" }

// Run executes the stage and retains its evidence even on failure.
func (x DiffStage) Run(ctx context.Context, _ *Session, e *Evidence) error {
	change := e.Artifacts.Change
	if change == nil || change.Before == nil || change.After == nil {
		return connector.ErrIncomplete
	}
	before, err := os.ReadFile(change.Before.Path)
	if err != nil {
		return err
	}
	after, err := os.ReadFile(change.After.Path)
	if err != nil {
		return err
	}
	ops := textdiff.Diff(textdiff.Lines(string(before)), textdiff.Lines(string(after)))
	change.Added, change.Removed = textdiff.Stats(ops)
	unified := textdiff.Unified("before/"+filepath.Base(change.Before.Path), filepath.Base(change.After.Path), ops, 3)
	change.Compared, change.Changed = true, unified != ""
	if !change.Changed {
		return nil
	}
	directory := filepath.Join(x.Directory, "diff")
	if err = storage.PrepareDirectory(directory); err != nil {
		return err
	}
	path := filepath.Join(directory, strings.TrimSuffix(filepath.Base(change.After.Path), ".txt")+".diff")
	if _, err = storage.Write(ctx, path, []byte(unified)); err != nil {
		return err
	}
	change.DiffFile = path
	return nil
}

// TFTPStage makes the device upload its configuration file. With a
// verification root the upload runs inside an archive transaction that marks
// the server clock, verifies the uploaded file and retrieves it.
type TFTPStage struct {
	Registry *vendors.Registry
	Pools    map[string]*archive.Pool
}

// Name returns the stable stage identifier recorded in reports.
func (TFTPStage) Name() string { return "tftp" }

// Admit checks whether the device and platform support this stage before I/O.
func (TFTPStage) Admit(_ fleet.Record, platform platform.Platform) batchreport.Status {
	if _, ok := platform.(transfer.TFTPPolicy); !ok {
		return batchreport.StatusUnsupportedOperation
	}
	return ""
}

// Plan adds the planned stage target without executing device operations.
func (TFTPStage) Plan(task fleet.Task, _ platform.Platform, target *batchreport.Target) {
	t := task.Target
	target.File, target.Server, target.VerificationRoot = t.Path, t.Server, t.Root
	target.SourceFile, target.SourceInterface, target.VRF = t.SourceFile, t.SourceInterface, t.VRF
}

// Run executes the stage and retains its evidence even on failure.
func (t TFTPStage) Run(ctx context.Context, s *Session, e *Evidence) error {
	target := s.Target
	upload := func(ctx context.Context, name string) (transfer.Receipt, error) {
		device, err := s.Device(ctx)
		if err != nil {
			return transfer.Receipt{}, err
		}
		opts := target.TFTPOptions
		opts.Path = name
		s.Stage("upload")
		result, err := transfer.TFTP(ctx, t.Registry, device, opts)
		if result.Receipt.Reported() {
			s.Stage("archive")
		}
		return result.Receipt, err
	}
	var receipt transfer.Receipt
	var err error
	var archived *archive.Receipt
	if pool := t.Pools[target.Root]; pool != nil {
		name, nameErr := s.Record.Filename()
		if nameErr != nil {
			return nameErr
		}
		name = strings.TrimSuffix(name, ".txt") + filepath.Ext(target.Path)
		result, uploadErr := pool.Upload(ctx, target.Path, name, upload)
		receipt, err, archived = result.Transfer, uploadErr, &result.Receipt
		e.Artifacts.Archive = reportArchive(result.Receipt)
	} else {
		receipt, err = upload(ctx, target.Path)
	}
	if receipt.Reported() {
		e.Artifacts.Transfer = reportTransfer(receipt)
		e.MarkPartial()
		if archived != nil && !archived.Complete() && err == nil {
			err = connector.ErrIncomplete
		}
	}
	if archived != nil && archived.Verified() {
		e.Verified = true
		if e.Artifacts.Transfer != nil {
			e.Artifacts.Transfer.Verification = "server_verified"
		}
	}
	return err
}

// ExecuteStage sends one validated script per platform inside one operation
// lease. The first rejected command stops the script; nothing is retried. On a
// commit-model platform the script is applied to the candidate configuration
// and committed.
type ExecuteStage struct {
	Scripts DeployScripts
	// CommitConfirm, when positive, commits with an automatic rollback after
	// this many minutes and then confirms it. Platforms without a confirmed
	// commit are skipped at plan time.
	CommitConfirm int
}

// Name returns the stable stage identifier recorded in reports.
func (ExecuteStage) Name() string { return "execute" }

// Admit checks whether the device and platform support this stage before I/O.
func (x ExecuteStage) Admit(record fleet.Record, platform platform.Platform) batchreport.Status {
	if script, ok := x.Scripts.For(record.Platform); !ok || len(script.Commands) == 0 {
		return batchreport.StatusMissingScript
	}
	if x.CommitConfirm > 0 {
		if committer, ok := connector.AsCommitter(platform); !ok || !committer.CommitTraits().ConfirmSupported {
			return batchreport.StatusConfirmUnsupported
		}
	}
	return ""
}

// Plan adds the planned stage target without executing device operations.
func (x ExecuteStage) Plan(task fleet.Task, _ platform.Platform, target *batchreport.Target) {
	script, _ := x.Scripts.For(task.Device.Platform)
	target.Script, target.Commands = script.Name, len(script.Commands)
}

// Run executes the stage and retains its evidence even on failure.
func (x ExecuteStage) Run(ctx context.Context, s *Session, e *Evidence) error {
	script, _ := x.Scripts.For(s.Record.Platform)
	device, err := s.Device(ctx)
	if err != nil {
		return err
	}
	evidence := &batchreport.Script{Name: script.Name, Commands: len(script.Commands), Attempts: []batchreport.Attempt{}}
	e.Artifacts.Script = evidence
	committer, commits := connector.AsCommitter(s.Platform)
	if commits {
		e.Artifacts.Commit = &batchreport.Commit{ConfirmMinutes: x.CommitConfirm}
	}
	return device.WithOperation(ctx, func(ctx context.Context, op *connector.Operation) error {
		var result connector.Result
		var err error
		if commits {
			result, err = op.Commit(ctx, script, connector.CommitOptions{ConfirmMinutes: x.CommitConfirm})
			e.Artifacts.Commit.Confirmed = err == nil
		} else {
			result, err = op.ExecuteScript(ctx, script, connector.ExecuteOptions{})
		}
		// Commands that wrap a candidate change have no script line.
		for _, step := range result.Steps() {
			if step.Command().Line > 0 {
				evidence.Accepted++
			}
		}
		for _, attempt := range result.Attempts() {
			failed := attempt.Err() != nil
			evidence.Attempts = append(evidence.Attempts, batchreport.Attempt{Line: attempt.Command().Line, Written: attempt.Written(), Complete: attempt.Complete(), Failed: failed})
			if failed && evidence.FailedLine == 0 {
				evidence.FailedLine = attempt.Command().Line
			}
			if attempt.Written() > 0 {
				// Any written command may have changed the device.
				e.MarkPartial()
			}
		}
		switch {
		case err == nil:
		case commits && committer.CommitTraits().CandidateShared && len(result.Attempts()) > 1:
			// The shared candidate keeps the uncommitted changes; the
			// operator must revert them. Nothing is reverted automatically.
			e.Outcome = batchreport.OutcomeCandidateDirty
		case errors.Is(err, connector.ErrDevice):
			e.Outcome = batchreport.OutcomeRejected
		}
		return err
	})
}

// DeployScripts selects the script for each canonical platform key. A
// platform without its own script uses Default; with neither it is skipped.
type DeployScripts struct {
	Default    *connector.Script
	ByPlatform map[string]connector.Script
}

// For returns the script that applies to platform.
func (s DeployScripts) For(platform string) (connector.Script, bool) {
	if script, ok := s.ByPlatform[platform]; ok {
		return script, true
	}
	if s.Default != nil {
		return *s.Default, true
	}
	return connector.Script{}, false
}

func reportBackup(receipt connector.BackupReceipt) *batchreport.Backup {
	b := &batchreport.Backup{
		Path: receipt.Path, Bytes: int64(receipt.Bytes), SHA256: receipt.SHA256, Change: receipt.Change,
		PreviousSHA256: receipt.PreviousSHA256, Encoding: receipt.Encoding,
		File:  batchreport.FileReceipt{Path: receipt.File.Path, State: string(receipt.File.State), Phase: receipt.File.Phase},
		Saved: receipt.HasSavedEvidence(), Complete: receipt.Complete(),
	}
	if source := receipt.Source; source != nil {
		b.Source = &batchreport.BackupSource{
			Path: source.Path, Bytes: source.Bytes, SHA256: source.SHA256, NoWriteVerified: source.NoWriteVerified,
			File: batchreport.FileReceipt{Path: source.File.Path, State: string(source.File.State), Phase: source.File.Phase},
		}
		for _, segment := range source.Segments {
			b.Source.Segments = append(b.Source.Segments, batchreport.SourceSegment{Step: segment.Step, Offset: segment.Offset, Bytes: segment.Bytes})
		}
	}
	if warning := receipt.TextWarning; warning != nil {
		b.TextWarning = &batchreport.TextWarning{Count: warning.Count, Positions: []batchreport.TextPosition{}}
		for _, position := range warning.Positions {
			b.TextWarning.Positions = append(b.TextWarning.Positions, batchreport.TextPosition{Offset: position.Offset, Line: position.Line, Column: position.Column})
		}
	}
	return b
}

func reportTransfer(receipt transfer.Receipt) *batchreport.Transfer {
	return &batchreport.Transfer{
		RemotePath: receipt.Path, Server: receipt.Server, ConfigurationKind: receipt.ConfigurationKind,
		SourceFile: receipt.SourceFile, Format: receipt.Format, Verification: string(receipt.Verification),
	}
}

func reportArchive(receipt archive.Receipt) *batchreport.ArchiveReceipt {
	r := &batchreport.ArchiveReceipt{
		Local:   batchreport.FileReceipt{Path: receipt.Local.Path, State: string(receipt.Local.State), Phase: receipt.Local.Phase},
		Cleanup: string(receipt.Cleanup),
	}
	if proof := receipt.Server; proof != nil {
		r.Server = &batchreport.ArchiveProof{Bytes: proof.Bytes, SHA256: proof.SHA256, ArchivePath: proof.ArchivePath, Verified: proof.Verified}
	}
	return r
}

// ReadOnlyClassifier is the platform capability exec requires: it reports
// whether a command can only read device state.
type ReadOnlyClassifier interface {
	IsReadOnly(command string) bool
}

// ExecStage runs read-only commands in one lease and saves each strict
// output body (prompt and command echo removed) to "<name>-<IP>.txt".
type ExecStage struct {
	Commands  []string
	Directory string
}

// Name returns the stable stage identifier recorded in reports.
func (ExecStage) Name() string { return "exec" }

// Admit refuses a platform unless every command is read-only for it, so no
// connection is opened for a command that could change the device.
func (x ExecStage) Admit(_ fleet.Record, platform platform.Platform) batchreport.Status {
	classifier, ok := platform.(ReadOnlyClassifier)
	if !ok {
		return batchreport.StatusUnsupportedOperation
	}
	for _, command := range x.Commands {
		if !classifier.IsReadOnly(command) {
			return batchreport.StatusNotReadOnly
		}
	}
	return ""
}

// Plan adds the planned stage target without executing device operations.
func (x ExecStage) Plan(task fleet.Task, _ platform.Platform, target *batchreport.Target) {
	target.File, _ = task.Device.Filename()
	target.Commands = len(x.Commands)
}

// Run executes the stage and retains its evidence even on failure.
func (x ExecStage) Run(ctx context.Context, s *Session, e *Evidence) error {
	name, err := s.Record.Filename()
	if err != nil {
		return err
	}
	device, err := s.Device(ctx)
	if err != nil {
		return err
	}
	path := filepath.Join(x.Directory, name)
	var body strings.Builder
	runErr := device.WithOperation(ctx, func(ctx context.Context, op *connector.Operation) error {
		for _, text := range x.Commands {
			result, err := op.ExecuteCommand(ctx, connector.Command{Text: text}, connector.ExecuteOptions{})
			if err != nil {
				return err
			}
			step, err := result.SingleAccepted(text)
			if err != nil {
				return err
			}
			output, err := step.Body()
			if err != nil {
				return err
			}
			sum := sha256.Sum256([]byte(output))
			e.Artifacts.Outputs = append(e.Artifacts.Outputs, batchreport.Output{Command: text, Path: path, Bytes: int64(len(output)), SHA256: hex.EncodeToString(sum[:])})
			fmt.Fprintf(&body, "### %s\n%s", text, output)
			if !strings.HasSuffix(output, "\n") {
				body.WriteString("\n")
			}
		}
		return nil
	})
	if body.Len() > 0 {
		if _, err := storage.Write(ctx, path, []byte(body.String())); err != nil {
			return errors.Join(runErr, err)
		}
		e.MarkPartial()
	}
	return runErr
}

// RemoteStage makes the device export its configuration to a remote server
// with its native client (SCP or FTP). Completion is device-reported only.
type RemoteStage struct {
	Registry platform.Registry
	// Options carries server, protocol, username and password; Path is the
	// remote directory, completed per device with "<host>-<stamp>.conf".
	Options transfer.RemoteOptions
	Stamp   string
}

// Name returns the stable stage identifier recorded in reports.
func (RemoteStage) Name() string { return "remote" }

// Admit checks whether the device and platform support this stage before I/O.
func (RemoteStage) Admit(_ fleet.Record, platform platform.Platform) batchreport.Status {
	if _, ok := platform.(transfer.RemoteBackupPolicy); !ok {
		return batchreport.StatusUnsupportedOperation
	}
	return ""
}

// Plan adds the planned stage target without executing device operations.
func (x RemoteStage) Plan(task fleet.Task, _ platform.Platform, target *batchreport.Target) {
	target.Server, target.File = x.Options.Server, x.path(task.Device.Host)
}

// Run executes the stage and retains its evidence even on failure.
func (x RemoteStage) Run(ctx context.Context, s *Session, e *Evidence) error {
	device, err := s.Device(ctx)
	if err != nil {
		return err
	}
	options := x.Options
	options.Path = x.path(s.Record.Host)
	result, err := transfer.RemoteBackup(ctx, x.Registry, device, options)
	if result.Receipt.Reported() {
		e.Artifacts.Remote = &batchreport.Remote{Server: result.Receipt.Server, Destination: result.Receipt.Path, Protocol: result.Receipt.Protocol, Reported: true}
		e.MarkPartial()
	}
	return err
}

func (x RemoteStage) path(host string) string {
	name := strings.ReplaceAll(host, ":", "_") + "-" + x.Stamp + ".conf"
	if x.Options.Path == "" {
		return name
	}
	return strings.TrimSuffix(x.Options.Path, "/") + "/" + name
}

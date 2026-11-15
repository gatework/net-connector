package connector

import (
	"context"
	"errors"
	"io"
	"os"
	"strings"
	"syscall"
	"time"

	expect "github.com/gatework/go-expect"

	"github.com/gatework/net-connector/internal/terminal"
	"github.com/gatework/net-connector/internal/textcodec"
	"github.com/gatework/net-connector/storage"
)

type renderedConfig struct{}

type configTextMode uint8

const (
	configTextRendered configTextMode = iota
	configTextBackupSource
	configTextPreserveInvalid
)

func (renderedConfig) MatchPrompt(_ string, current string) (expect.Pattern, error) {
	return expect.Line(current), nil
}
func (renderedConfig) Validate(context.Context, Command, StepResult, Executor) error { return nil }
func (renderedConfig) Finish(_ context.Context, r Result) (string, error) {
	if len(r.steps) == 0 {
		return "", ErrIncomplete
	}
	return r.steps[len(r.steps)-1].Response().Rendered()
}

// RunningConfig collects a nonempty configuration under the device operation lease.
func (d *Device) RunningConfig(ctx context.Context) (Result, error) {
	if e := d.acquire(); e != nil {
		return Result{}, e
	}
	defer d.release()
	ctx, cancel := d.operationContext(ctx)
	defer cancel()
	return d.runningConfig(ctx)
}
func (d *Device) runningConfig(ctx context.Context) (Result, error) { return d.collectConfig(ctx) }
func (d *Device) collectConfig(ctx context.Context) (Result, error) {
	return d.collectConfigWithMode(ctx, configTextRendered)
}
func (d *Device) collectConfigWithMode(ctx context.Context, mode configTextMode) (result Result, err error) {
	if mode > configTextPreserveInvalid {
		return Result{}, ErrInvalid
	}
	if len(d.terminal.ConfigCommands) == 0 {
		return Result{}, newError("configuration_error", "collect", Command{}, ErrUnsupported)
	}
	returned := false
	defer func() {
		if !returned {
			_ = d.closeResources()
		} else if err != nil {
			err = d.retireFailure(err)
		}
	}()
	result, err = func() (Result, error) {
		commands := make([]Command, len(d.terminal.ConfigCommands))
		for i, text := range d.terminal.ConfigCommands {
			commands[i] = Command{Text: text, OutputSensitive: true}
		}
		var strategy ConfigStrategy = renderedConfig{}
		custom := d.driver.NewConfigCollector()
		if custom != nil {
			strategy = custom
		}
		result, e := d.execute(ctx, Script{Commands: commands}, ExecuteOptions{textMode: mode}, strategy)
		if e != nil {
			return result, e
		}
		config, e := finishConfiguration(ctx, result, strategy, custom != nil)
		if e != nil {
			return result, e
		}
		result.config = &config
		return result, ctx.Err()
	}()
	returned = true
	return
}

// finishConfiguration checks the collected result and extracts a nonempty configuration.
func finishConfiguration(ctx context.Context, result Result, strategy ConfigStrategy, custom bool) (string, error) {
	if len(result.steps) == 0 {
		return "", newError("incomplete_configuration", "collect", Command{}, ErrIncomplete)
	}
	config, e := strategy.Finish(ctx, result)
	if e != nil {
		return "", configurationFailure(Command{}, e)
	}
	if strings.TrimSpace(config) == "" {
		return "", ErrIncomplete
	}
	hasBody := custom
	for _, step := range result.steps[len(result.steps)-1:] {
		body, e := step.Response().Rendered()
		if e != nil {
			return "", e
		}
		prompt, e := step.Response().Prompt()
		if e != nil {
			return "", e
		}
		body = strings.TrimSuffix(strings.TrimSpace(body), strings.TrimSpace(prompt))
		body = strings.TrimSpace(body)
		if after, ok := strings.CutPrefix(body, step.command.Text); ok {
			body = strings.TrimSpace(after)
		}
		if body != "" {
			hasBody = true
		}
	}
	if !hasBody {
		return "", newError("incomplete_configuration", "collect", Command{}, ErrIncomplete)
	}
	return config, nil
}

// SaveConfig distinguishes command completion from platform-confirmed persistence.
func (d *Device) SaveConfig(ctx context.Context, opts ExecuteOptions) (Result, error) {
	if len(d.terminal.SaveCommands) == 0 {
		return Result{}, ErrUnsupported
	}
	if opts.MaxOutputBytes < 0 || opts.PreserveSessionOnRejection {
		return Result{}, ErrInvalid
	}
	if err := d.acquire(); err != nil {
		return Result{}, err
	}
	defer d.release()
	ctx, cancel := d.operationContext(ctx)
	defer cancel()
	return d.saveConfig(ctx, opts)
}
func (d *Device) saveConfig(ctx context.Context, opts ExecuteOptions) (result Result, err error) {
	if len(d.terminal.SaveCommands) == 0 {
		return result, ErrUnsupported
	}
	if opts.MaxOutputBytes < 0 || opts.PreserveSessionOnRejection {
		return result, ErrInvalid
	}
	returned := false
	defer func() {
		if !returned {
			_ = d.closeResources()
		} else if err != nil {
			err = d.retireFailure(err)
		}
	}()
	result, err = d.save(ctx, opts)
	returned = true
	return
}
func (d *Device) save(ctx context.Context, opts ExecuteOptions) (result Result, err error) {
	commands := make([]Command, len(d.terminal.SaveCommands))
	for i, text := range d.terminal.SaveCommands {
		commands[i] = Command{Text: text}
	}
	result, err = d.execute(ctx, Script{Commands: commands}, opts, nil)
	if err != nil {
		return
	}
	if err = d.driver.ValidateSave(ctx, result); err != nil {
		return result, newError("persistence_unconfirmed", "persist", Command{}, err)
	}
	return result, ctx.Err()
}

// BackupOptions controls backup publication, locking and source-byte retention.
type BackupOptions struct {
	// PreserveInvalidEncoding retains original configuration bytes with explicit warnings when strict decoding fails.
	PreserveInvalidEncoding bool
	// TextOnly publishes only strictly decoded configuration text; no raw sidecar.
	TextOnly      bool
	Path          string
	LockTimeout   time.Duration
	RejectSymlink bool
}

// BackupReceipt retains device completion and separate text/source persistence evidence.
type BackupReceipt struct {
	TextOnly        bool            `json:"text_only,omitempty"`
	Source          *BackupSource   `json:"source,omitempty"`
	Encoding        string          `json:"encoding,omitempty"`
	TextWarning     *TextWarning    `json:"text_warning,omitempty"`
	Path            string          `json:"path"`
	Bytes           int             `json:"bytes"`
	SHA256          string          `json:"sha256"`
	CollectedAt     time.Time       `json:"collected_at"`
	Change          string          `json:"change"`
	PreviousSHA256  string          `json:"previous_sha256,omitempty"`
	DeviceCompleted bool            `json:"device_completed"`
	NoWriteVerified bool            `json:"no_write_verified"`
	File            storage.Receipt `json:"file"`
}

// Backup collects configuration and publishes its text and optional raw source with receipts.
func (d *Device) Backup(ctx context.Context, opts BackupOptions) (receipt BackupReceipt, err error) {
	if e := d.acquire(); e != nil {
		return receipt, e
	}
	defer d.release()
	ctx, cancel := d.operationContext(ctx)
	defer cancel()
	lock, e := storage.Acquire(ctx, opts.Path, opts.LockTimeout)
	if e != nil {
		return receipt, e
	}
	defer func() {
		if e := lock.Close(); e != nil {
			err = joinFailures(err, newError("backup_finalize_failed", "backup", Command{}, e))
		}
	}()
	mode := configTextRendered
	if !opts.TextOnly {
		mode = configTextBackupSource
	} else if opts.PreserveInvalidEncoding {
		mode = configTextPreserveInvalid
	}
	result, e := d.collectConfigWithMode(ctx, mode)
	if e != nil {
		return receipt, e
	}
	contents, _ := result.Config()
	digest := hashParts([]string{contents})
	receipt = BackupReceipt{TextOnly: opts.TextOnly, Path: lock.Path(), Bytes: len(contents), SHA256: digest, CollectedAt: time.Now().UTC(), DeviceCompleted: true, File: storage.Receipt{Path: lock.Path(), State: "not_committed", Phase: "compare"}}
	previous, e := storage.Inspect(ctx, lock.Path(), d.config.MaxOutputBytes)
	if e != nil && !errors.Is(e, os.ErrNotExist) && !(errors.Is(e, syscall.ELOOP) && !opts.RejectSymlink) {
		return receipt, e
	}
	if !opts.TextOnly {
		raw, source, encoding, warning := backupSource(result)
		receipt.Source, receipt.Encoding, receipt.TextWarning = source, encoding, warning
		if e = persistBackupSource(ctx, source, raw, lock.Path()); e != nil {
			return receipt, e
		}
	} else {
		for _, step := range result.steps {
			encoding := step.Response().Encoding()
			if receipt.Encoding == "" {
				receipt.Encoding = encoding
			} else if receipt.Encoding != encoding {
				receipt.Encoding = "mixed"
			}
		}
	}
	if opts.TextOnly && opts.PreserveInvalidEncoding {
		_, _, count, offsets := textcodec.BackupViewSource(contents)
		receipt.TextWarning = sourceWarning(contents, count, offsets)
	}
	receipt.PreviousSHA256 = previous.SHA256
	switch previous.SHA256 {
	case "":
		receipt.Change = "created"
	case digest:
		receipt.Change = "unchanged"
	default:
		receipt.Change = "changed"
	}
	if receipt.Change == "unchanged" && previous.Mode.Perm() == 0600 && storage.SameEntry(lock.Path(), previous) {
		receipt.NoWriteVerified = true
		return receipt, nil
	}
	receipt.File, err = storage.WriteStream(ctx, lock.Path(), func(w io.Writer) error {
		_, e := io.WriteString(w, contents)
		return e
	})
	err = backupPersistenceFailure(receipt.File, err)
	return
}

// BackupPersistenceError marks a failure after the backup file was committed.
// Backup's returned receipt retains the committed/durable boundary. Unwrap
// preserves the connector metadata and original storage error for explicit use.
// Before commit, Backup returns the original storage.WriteError instead.
type BackupPersistenceError struct{ failure *Error }

func (e *BackupPersistenceError) Error() string { return e.failure.Error() }

// GoString formats safe metadata without the original storage error.
func (e *BackupPersistenceError) GoString() string { return e.Error() }
func (e *BackupPersistenceError) Unwrap() error    { return e.failure }

func configurationFailure(c Command, err error) error {
	if _, ok := errors.AsType[*Error](err); ok {
		return err
	}
	if errors.Is(err, ErrIncomplete) {
		return newError("incomplete_configuration", "collect", c, err)
	}
	if errors.Is(err, terminal.ErrEncoding) {
		return newError("invalid_output_encoding", "parse", c, err)
	}
	return newError("configuration_error", "collect", c, err)
}

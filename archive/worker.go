// Package archive implements the versioned, single-transaction archive protocol.
package archive

import (
	"bufio"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"path/filepath"
	"regexp"
	"slices"
	"time"

	"golang.org/x/sys/unix"
	"golang.org/x/text/cases"
	"golang.org/x/text/unicode/norm"
)

// Version is the supported archive wire protocol version.
const Version = 2

// ControlLimit bounds one encoded control frame in bytes.
const ControlLimit = 16 << 10

// PayloadLimit bounds a single archived payload in bytes.
const PayloadLimit = 64 << 20

// ChunkSize bounds each streamed payload chunk in bytes.
const ChunkSize = 64 << 10

// ErrArchive means the archive transaction could not be confirmed.
var ErrArchive = errors.New("tftp_archive_failed")
var capabilities = []string{"target_lock", "preserve_previous", "stable_sha256", "binary_delivery", "confirmed_cleanup", "daily_latest", "stage_timeouts"}
var archiveBatchPattern = regexp.MustCompile(`^(?:[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}(?:_[0-9]{2,})*|[0-9_-]+-ssh-[a-f0-9]{16})$`)

// Serve owns one transaction. Readers/writers must unblock on disconnect or context cancellation.
// A failure never removes an unconfirmed staging upload or replays a device operation.
func Serve(ctx context.Context, input io.Reader, output io.Writer) (err error) {
	return serve(ctx, input, output, controlTimeout)
}

func serve(parent context.Context, input io.Reader, output io.Writer, control time.Duration) (err error) {
	var setters []func(time.Time) error
	if d, ok := input.(interface{ SetReadDeadline(t time.Time) error }); ok {
		setters = append(setters, d.SetReadDeadline)
	}
	if d, ok := output.(interface{ SetWriteDeadline(t time.Time) error }); ok {
		setters = append(setters, d.SetWriteDeadline)
	}
	ctx := parent
	finish := func() {}
	setDeadline := func(deadline time.Time) error {
		finish()
		// A setter can fail before the new cancellation callback is installed.
		// Never retain an already-stopped callback whose done channel cannot close.
		finish = func() {}
		var cancel context.CancelFunc
		ctx, cancel = context.WithDeadline(parent, deadline) //nolint:fatcontext // each deadline replaces the previous one; parent never nests
		deadline, _ = ctx.Deadline()
		for _, set := range setters {
			if e := set(deadline); e != nil {
				cancel()
				return e
			}
		}
		stopped := make(chan struct{})
		stop := context.AfterFunc(ctx, func() {
			for _, set := range setters {
				_ = set(time.Now())
			}
			close(stopped)
		})
		finish = func() {
			if !stop() {
				<-stopped
			}
			cancel()
		}
		return ctx.Err()
	}
	setStage := func(timeout time.Duration) error {
		if e := ctx.Err(); e != nil {
			return e
		}
		return setDeadline(time.Now().Add(timeout))
	}
	defer func() { finish() }()
	if e := setStage(control); e != nil {
		return e
	}

	defer func() {
		if err != nil && ctx.Err() == nil {
			_ = writeFrame(output, frame{OK: false, Error: "tftp_archive_failed"})
		}
	}()
	return serveRequest(func() context.Context { return ctx }, setStage, setDeadline, input, output, control) //nolint:contextcheck // The transaction receives this request context through its current callback.
}

// archiveTransaction owns one request and its phase state; current returns the
// active deadline context, which is replaced between protocol stages.
type archiveTransaction struct {
	control                      time.Duration
	current                      func() context.Context
	setStage                     func(time.Duration) error
	setDeadline                  func(time.Time) error
	reader                       *bufio.Reader
	output                       io.Writer
	req                          Request
	timeouts                     Timeouts
	daily                        bool
	dirs                         *directories
	batch, locks, lockFD         int
	lockName                     string
	previous, currentFile, saved *fingerprint
	started                      int64
	digest                       string
}

func serveRequest(current func() context.Context, setStage func(time.Duration) error, setDeadline func(time.Time) error, input io.Reader, output io.Writer, control time.Duration) error {
	t := &archiveTransaction{current: current, setStage: setStage, setDeadline: setDeadline, reader: bufio.NewReaderSize(input, ControlLimit+1), output: output, lockFD: -1, control: control}
	return t.run()
}
func (t *archiveTransaction) run() error {
	req, e := readRequest(t.reader)
	if e != nil {
		return e
	}
	t.req = req
	if req.Action == "probe" {
		return t.ready()
	}
	if req.Action != "preflight" {
		if req.Timeouts == nil {
			return ErrArchive
		}
		t.timeouts, e = req.Timeouts.decode()
		if e != nil {
			return e
		}
		if e = t.setStage(t.timeouts.Prepare); e != nil {
			return e
		}
	}
	t.daily = dailyBatch(req.Batch)
	if !isSafeName(req.Filename) || !isSafeName(req.ArchiveName) || !t.daily && !archiveBatchPattern.MatchString(req.Batch) {
		return ErrArchive
	}
	t.dirs, e = openDirectories(req.Root)
	if e != nil {
		return e
	}
	defer t.dirs.close()
	archive, e := t.dirs.private(t.dirs.root, "archive")
	if e != nil {
		return e
	}
	t.batch, e = t.dirs.private(archive, req.Batch)
	if e != nil {
		return e
	}
	t.locks, e = t.dirs.private(t.dirs.root, ".net-connector-locks")
	if e != nil {
		return e
	}
	if req.Action == "preflight" {
		return t.preflight()
	}
	if req.Action != "" && req.Action != "upload" {
		return ErrArchive
	}
	defer func() {
		if t.lockFD >= 0 {
			_ = unix.Close(t.lockFD)
		}
	}()
	if e = t.prepareUpload(); e != nil {
		return e
	}
	return t.acceptVerification()
}
func (t *archiveTransaction) ready() error {
	return writeFrame(t.output, frame{OK: true, Phase: "ready", Version: Version, Capabilities: slices.Clone(capabilities)})
}
func (t *archiveTransaction) preflight() error {
	if _, e := t.markerTime(); e != nil {
		return e
	}
	if e := t.dirs.verify(); e != nil {
		return e
	}
	return t.ready()
}
func (t *archiveTransaction) markerTime() (int64, error) {
	f, name, e := temporary(t.dirs.root, ".net-connector-upload-")
	if e != nil {
		return 0, e
	}
	s, e := statFD(int(f.Fd()))
	if e == nil {
		e = f.Sync()
	}
	ce := f.Close()
	ue := unix.Unlinkat(t.dirs.root, name, 0)
	if e == nil {
		e = ce
	}
	if e == nil {
		e = ue
	}
	return mtime(s), e
}
func (t *archiveTransaction) verify() error {
	if e := t.current().Err(); e != nil {
		return e
	}
	if e := t.dirs.verify(); e != nil {
		return e
	}
	return verifyLock(t.locks, t.lockName, t.lockFD)
}
func (t *archiveTransaction) prepareUpload() error {
	var e error
	t.lockName = fmt.Sprintf("%x", sha256.Sum256([]byte(norm.NFC.String(cases.Fold().String(norm.NFC.String(t.req.Filename))))))
	t.lockFD, e = lockArchiveTarget(t.current(), t.locks, t.lockName)
	if e != nil {
		return e
	}

	if e = t.verify(); e != nil {
		return e
	}
	old, previous, e := readFile(t.current(), t.dirs.root, t.req.Filename, true, nil)
	if e != nil {
		return e
	}
	t.previous = previous
	if previous != nil {
		prior, e := t.dirs.private(t.batch, "previous")
		if e != nil {
			return e
		}
		if e = persistMode(t.current(), prior, t.req.ArchiveName, t.dirs.root, t.req.Filename, *previous, old, t.daily); e != nil {
			return e
		}
	}
	t.started, e = t.markerTime()
	if e != nil {
		return e
	}
	if e = t.verify(); e != nil {
		return e
	}
	// Once ready is published the client owns a full upload window. Neither a
	// slow ready write nor scheduling after delivery may consume that window.
	// The client enforces the upload budget; the worker keeps a bounded watchdog.
	if e = writeFrame(t.output, frame{OK: true, Phase: "ready"}); e != nil {
		return e
	}
	if e = t.setDeadline(time.Now().Add(t.timeouts.Upload + t.control)); e != nil {
		return e
	}
	return nil
}
func (t *archiveTransaction) acceptVerification() error {
	next, e := readRequest(t.reader)
	if e != nil {
		return e
	}
	if next.Action != "verify" {
		if next.Action == "abort" {
			return nil
		}
		return ErrArchive
	}
	if e = t.setStage(t.timeouts.Verify); e != nil {
		return e
	}
	if e = t.verify(); e != nil {
		return e
	}
	if e := t.verifyUpload(); e != nil {
		return e
	}
	if e := t.deliver(); e != nil {
		return e
	}
	return t.cleanup()
}
func (t *archiveTransaction) verifyUpload() error {
	digest, current, e := readFile(t.current(), t.dirs.root, t.req.Filename, false, nil)
	if e != nil || current == nil || current.size == 0 || t.previous != nil && *t.previous == *current || current.mtime < t.started {
		return ErrArchive
	}
	if e = persistMode(t.current(), t.batch, t.req.ArchiveName, t.dirs.root, t.req.Filename, *current, digest, t.daily); e != nil {
		return e
	}
	t.digest, t.currentFile = digest, current
	archived, saved, e := readFile(t.current(), t.batch, t.req.ArchiveName, false, nil)
	if e != nil || saved == nil || archived != digest || saved.size != current.size {
		return ErrArchive
	}
	if e = t.verify(); e != nil {
		return e
	}
	if e = writeFrame(t.output, frame{OK: true, Phase: "archived", Bytes: current.size, SHA256: digest, ArchivePath: filepath.Join(t.req.Root, "archive", t.req.Batch, t.req.ArchiveName)}); e != nil {
		return e
	}
	t.saved = saved
	return nil
}
func (t *archiveTransaction) deliver() error {
	delivered, check, e := readFile(t.current(), t.batch, t.req.ArchiveName, false, func(b []byte) error { return writeAll(t.output, b) })
	if e != nil || check == nil || *check != *t.saved || delivered != t.digest {
		return ErrArchive
	}
	if e = t.verify(); e != nil {
		return e
	}
	verifyDeadline, _ := t.current().Deadline()
	if e = writeFrame(t.output, frame{OK: true, Phase: "delivered"}); e != nil {
		return e
	}
	// Local fsync/rename/directory sync still belong to verification. Only the
	// next control frame gets handoff allowance; no file work uses this margin.
	if e = t.setDeadline(verifyDeadline.Add(t.control)); e != nil {
		return e
	}
	return nil
}
func (t *archiveTransaction) cleanup() error {
	action, e := readRequest(t.reader)
	if e != nil {
		return e
	}
	if action.Action == "cleanup" {
		if e = t.setStage(t.timeouts.Cleanup); e != nil {
			return e
		}
		if action.SHA256 != t.digest {
			return ErrArchive
		}
		if e = t.verify(); e != nil {
			return e
		}
		uploaded, check, e := readFile(t.current(), t.dirs.root, t.req.Filename, false, nil)
		if e != nil || check == nil || *check != *t.currentFile || uploaded != t.digest {
			return ErrArchive
		}
		if e = t.verify(); e != nil {
			return e
		}
		if e = unix.Unlinkat(t.dirs.root, t.req.Filename, 0); e != nil {
			return e
		}
		if e = unix.Fsync(t.dirs.root); e != nil {
			return e
		}
		if e = t.current().Err(); e != nil {
			return e
		}
		return writeFrame(t.output, frame{OK: true, Phase: "complete"})
	}
	if action.Action == "abort" {
		return nil
	}
	return ErrArchive
}

package archive

import (
	"bufio"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/gatework/net-connector/storage"
	"github.com/gatework/net-connector/transfer"
)

func transactionClient(t *testing.T, limits Timeouts) (*Client, string) {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	c, err := NewClient(ClientOptions{Root: root, Directory: t.TempDir(), Launcher: LocalLauncher(), Timeouts: limits})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := c.Close(); err != nil {
			t.Error(err)
		}
	})
	if err := c.Prepare(t.Context()); err != nil {
		t.Fatal(err)
	}
	return c, root
}

func writeUpload(root string) func(context.Context, string) (transfer.Receipt, error) {
	return func(ctx context.Context, name string) (transfer.Receipt, error) {
		if err := ctx.Err(); err != nil {
			return transfer.Receipt{}, err
		}
		err := os.WriteFile(filepath.Join(root, name), []byte("verified configuration\n"), 0600)
		return transfer.Receipt{Path: name, Verification: transfer.VerificationDeviceReported}, err
	}
}

func TestUploadWindowStartsAfterTargetLock(t *testing.T) {
	first, root := transactionClient(t, Timeouts{})
	second, err := NewClient(ClientOptions{Root: root, Directory: t.TempDir(), Launcher: LocalLauncher(), Timeouts: Timeouts{Prepare: time.Second, Upload: 200 * time.Millisecond}})
	if err != nil {
		t.Fatal(err)
	}
	defer second.Close()
	if err := second.Prepare(t.Context()); err != nil {
		t.Fatal(err)
	}
	entered, release := make(chan struct{}), make(chan struct{})
	firstDone := make(chan error, 1)
	go func() {
		_, err := first.Upload(t.Context(), "fixed.cfg", "first.cfg", func(ctx context.Context, _ string) (transfer.Receipt, error) {
			close(entered)
			select {
			case <-release:
			case <-ctx.Done():
			}
			return transfer.Receipt{}, ErrArchive
		})
		firstDone <- err
	}()
	<-entered
	// Wait beyond the second client's entire upload budget while its target is locked.
	secondDone := make(chan error, 1)
	go func() {
		_, err := second.Upload(t.Context(), "fixed.cfg", "second.cfg", func(ctx context.Context, name string) (transfer.Receipt, error) {
			deadline, ok := ctx.Deadline()
			if !ok || time.Until(deadline) < 150*time.Millisecond {
				return transfer.Receipt{}, fmt.Errorf("upload window consumed by lock wait")
			}
			return writeUpload(root)(ctx, name)
		})
		secondDone <- err
	}()
	time.Sleep(250 * time.Millisecond)
	close(release)
	<-firstDone
	if err := <-secondDone; err != nil {
		t.Fatal(err)
	}
}

func TestPoolQueueAndTargetPreparationShareDeadline(t *testing.T) {
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	p, err := NewPool(PoolOptions{Root: root, Directory: t.TempDir(), Parallel: 1, Timeouts: Timeouts{Prepare: 150 * time.Millisecond}})
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	if err = p.Prepare(t.Context(), nil); err != nil {
		t.Fatal(err)
	}
	slot := <-p.available
	launched := make(chan struct{})
	p.clients[0].launch = func(ctx context.Context) (Channel, error) { close(launched); return LocalLauncher()(ctx) }
	// Hold the target lock through a separate real transaction.
	holder, _ := NewClient(ClientOptions{Root: root, Directory: t.TempDir(), Launcher: LocalLauncher()})
	defer holder.Close()
	if err = holder.Prepare(t.Context()); err != nil {
		t.Fatal(err)
	}
	held, release := make(chan struct{}), make(chan struct{})
	holderDone := make(chan error, 1)
	go func() {
		_, err := holder.Upload(t.Context(), "fixed.cfg", "holder.cfg", func(context.Context, string) (transfer.Receipt, error) {
			close(held)
			<-release
			return transfer.Receipt{}, ErrArchive
		})
		holderDone <- err
	}()
	<-held
	called := false
	done := make(chan error, 1)
	started := time.Now()
	go func() {
		_, err := p.Upload(t.Context(), "fixed.cfg", "waiting.cfg", func(context.Context, string) (transfer.Receipt, error) { called = true; return transfer.Receipt{}, nil })
		done <- err
	}()
	time.Sleep(100 * time.Millisecond)
	p.available <- slot
	<-launched
	err = <-done
	close(release)
	<-holderDone
	if called || !errors.Is(err, context.DeadlineExceeded) || time.Since(started) > 280*time.Millisecond {
		t.Fatalf("called=%v elapsed=%s err=%v", called, time.Since(started), err)
	}
}

func TestReportedUploadErrorStillPreservesVerifiedArchive(t *testing.T) {
	c, root := transactionClient(t, Timeouts{Upload: 20 * time.Millisecond, Verify: time.Second})
	calls := 0
	result, err := c.Upload(t.Context(), "running.cfg", "device.cfg", func(ctx context.Context, name string) (transfer.Receipt, error) {
		calls++
		receipt, err := writeUpload(root)(ctx, name)
		if err != nil {
			return receipt, err
		}
		<-ctx.Done()
		return receipt, ctx.Err()
	})
	if !errors.Is(err, context.DeadlineExceeded) || !result.Transfer.Reported() || !result.Receipt.Verified() || !result.Receipt.Local.Durable() || result.Receipt.Cleanup != CleanupNotRequested || calls != 1 {
		t.Fatalf("result=%+v err=%v calls=%d", result, err, calls)
	}
	if _, err := os.Stat(filepath.Join(root, "running.cfg")); err != nil {
		t.Fatal("uncertain upload staging removed", err)
	}
}

func TestLocalPersistenceFailureKeepsServerProofAndCommitReceipt(t *testing.T) {
	for _, afterCommit := range []bool{false, true} {
		t.Run(fmt.Sprint(afterCommit), func(t *testing.T) {
			c, root := transactionClient(t, Timeouts{})
			c.persist = func(ctx context.Context, path string, produce func(io.Writer) error) (storage.Receipt, error) {
				if !afterCommit {
					return storage.Receipt{Path: path, State: storage.StateNotCommitted, Phase: "temporary_file"}, syscall.ENOSPC
				}
				r, err := storage.WriteStream(ctx, path, produce)
				if err != nil {
					return r, err
				}
				r.State = storage.StateCommitted
				r.Phase = "directory_sync"
				return r, &storage.WriteError{Receipt: r, Cause: syscall.EIO}
			}
			result, err := c.Upload(t.Context(), "running.cfg", "device.cfg", writeUpload(root))
			if err == nil || !result.Receipt.Verified() || result.Receipt.Local.Committed() != afterCommit || result.Receipt.Cleanup != CleanupNotRequested {
				t.Fatalf("result=%+v err=%v", result, err)
			}
			if _, err := os.Stat(filepath.Join(root, "running.cfg")); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestLocalCommitDoesNotConsumeCleanupWindow(t *testing.T) {
	const cleanupBudget = time.Second
	c, root := transactionClient(t, Timeouts{Verify: 5 * time.Second, Cleanup: cleanupBudget})
	c.persist = func(ctx context.Context, path string, produce func(io.Writer) error) (storage.Receipt, error) {
		r, err := storage.WriteStream(ctx, path, produce)
		// Exceed the cleanup budget while leaving real filesystem cleanup enough
		// scheduling headroom under race instrumentation on shared CI runners.
		time.Sleep(cleanupBudget + 100*time.Millisecond)
		return r, err
	}
	result, err := c.Upload(t.Context(), "running.cfg", "device.cfg", writeUpload(root))
	if err != nil || !result.Receipt.Complete() {
		t.Fatalf("result=%+v err=%v", result, err)
	}
}

func scriptedLauncher(run func(context.Context, net.Conn)) Launcher {
	return func(parent context.Context) (Channel, error) {
		ctx, cancel := context.WithCancel(parent)
		client, server := net.Pipe()
		done := make(chan struct{})
		go func() { defer close(done); defer server.Close(); run(ctx, server) }()
		return Channel{Input: client, Output: client, Close: func() error { cancel(); _ = client.Close(); <-done; return nil }}, nil
	}
}

func TestCleanupAcknowledgementFailureRetainsDurableArtifact(t *testing.T) {
	for _, lost := range []bool{false, true} {
		t.Run(fmt.Sprint(lost), func(t *testing.T) {
			c, root := transactionClient(t, Timeouts{Cleanup: 30 * time.Millisecond})
			var cleanup atomic.Bool
			c.launch = scriptedLauncher(func(ctx context.Context, server net.Conn) {
				reader := bufio.NewReader(server)
				request, e := readRequest(reader)
				if e != nil {
					return
				}
				if e = writeFrame(server, frame{OK: true, Phase: "ready"}); e != nil {
					return
				}
				requestVerify, e := readRequest(reader)
				if e != nil || requestVerify.Action != "verify" {
					return
				}
				body := []byte("configuration\n")
				digest := fmt.Sprintf("%x", sha256.Sum256(body))
				proof := frame{OK: true, Phase: "archived", Bytes: int64(len(body)), SHA256: digest, ArchivePath: filepath.Join(root, "archive", request.Batch, request.ArchiveName)}
				if writeFrame(server, proof) != nil {
					return
				}
				if writeAll(server, body) != nil {
					return
				}
				if writeFrame(server, frame{OK: true, Phase: "delivered"}) != nil {
					return
				}
				action, e := readRequest(reader)
				if e != nil || action.Action != "cleanup" {
					return
				}
				cleanup.Store(true)
				if !lost {
					<-ctx.Done()
				} // lost acknowledgement vs blocked acknowledgement
			})
			result, err := c.Upload(t.Context(), "running.cfg", "device.cfg", writeUpload(root))
			var ae *Error
			if err == nil || !errors.As(err, &ae) || ae.Phase != "cleanup" || !result.Receipt.Verified() || !result.Receipt.Local.Durable() || result.Receipt.Cleanup != CleanupUnconfirmed || !cleanup.Load() {
				t.Fatalf("result=%+v err=%v", result, err)
			}
		})
	}
}

func TestProtocolRequiresDeadlineAndRejectsOldWorker(t *testing.T) {
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	p := NewProtocol(a, a)
	if err := p.Send(context.Background(), Request{Action: "probe"}); !errors.Is(err, ErrArchive) {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	go func() { _, _ = io.WriteString(b, "{\"ok\":true,\"version\":1,\"phase\":\"ready\"}\n") }()
	if _, err := p.Expect(ctx, "ready"); !errors.Is(err, ErrArchive) {
		t.Fatal(err)
	}
}

func TestVersionMismatchAndInvalidBudgetsFailBeforeFiles(t *testing.T) {
	for _, request := range []string{
		`{"version":1,"root":"ROOT","filename":"config","archive_name":"device","batch":"2026-11-07"}`,
		`{"version":2,"root":"ROOT","filename":"config","archive_name":"device","batch":"2026-11-07","timeouts":{"prepare_ms":0,"upload_ms":1,"verify_ms":1,"cleanup_ms":1}}`,
		`{"version":2,"root":"ROOT","filename":"config","archive_name":"device","batch":"2026-11-07","timeouts":{"prepare_ms":1,"upload_ms":9223372036854775807,"verify_ms":1,"cleanup_ms":1}}`,
	} {
		root := t.TempDir()
		a, b := net.Pipe()
		done := make(chan error, 1)
		go func() { defer b.Close(); done <- Serve(t.Context(), b, b) }()
		_, err := io.WriteString(a, strings.ReplaceAll(request, "ROOT", root)+"\n")
		if err != nil {
			t.Fatal(err)
		}
		_, _ = io.ReadAll(a)
		_ = a.Close()
		if err := <-done; err == nil {
			t.Fatal("invalid request accepted")
		}
		entries, err := os.ReadDir(root)
		if err != nil || len(entries) != 0 {
			t.Fatal(entries, err)
		}
	}
}

func TestTimeoutBudgetSupportsLongUploadAndRejectsOverflow(t *testing.T) {
	limits := DefaultTimeouts()
	limits.Upload = 600 * time.Second
	normalized, err := limits.normalize()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	budget, err := normalized.wire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	got, err := budget.decode()
	if err != nil || got.Upload != 600*time.Second {
		t.Fatal(got, err)
	}
	limits.Upload = time.Duration(1<<63 - 1)
	if _, err := limits.normalize(); err == nil {
		t.Fatal("overflow accepted")
	}
}

type deadlineRecorder struct {
	net.Conn
	uploadWindow chan time.Duration
}

func (c *deadlineRecorder) SetReadDeadline(deadline time.Time) error {
	if left := time.Until(deadline); left > 500*time.Second {
		select {
		case c.uploadWindow <- left:
		default:
		}
	}
	return c.Conn.SetReadDeadline(deadline)
}

func TestWorkerUsesConfiguredLongUploadWindow(t *testing.T) {
	c, root := transactionClient(t, Timeouts{Upload: 600 * time.Second})
	window := make(chan time.Duration, 1)
	c.launch = scriptedLauncher(func(ctx context.Context, server net.Conn) {
		connection := &deadlineRecorder{Conn: server, uploadWindow: window}
		_ = Serve(ctx, connection, connection)
	})
	result, err := c.Upload(t.Context(), "running.cfg", "device.cfg", func(ctx context.Context, name string) (transfer.Receipt, error) {
		select {
		case left := <-window:
			if left < 600*time.Second {
				return transfer.Receipt{}, fmt.Errorf("worker upload window=%s", left)
			}
		case <-ctx.Done():
			return transfer.Receipt{}, ctx.Err()
		}
		return writeUpload(root)(ctx, name)
	})
	if err != nil || !result.Receipt.Complete() {
		t.Fatalf("result=%+v err=%v", result, err)
	}
}

func TestPreparationBoundsLauncherWithoutExpiringWorker(t *testing.T) {
	c, _ := transactionClient(t, Timeouts{})
	// Only the blocked launcher uses this short budget; filesystem preflight
	// must complete before exercising the transaction preparation deadline.
	c.timeouts.Prepare = 25 * time.Millisecond
	var calls atomic.Int32
	c.launch = func(ctx context.Context) (Channel, error) {
		calls.Add(1)
		<-ctx.Done()
		return Channel{}, errors.Join(ctx.Err(), syscall.EIO)
	}
	_, err := c.Upload(t.Context(), "running.cfg", "device.cfg", func(context.Context, string) (transfer.Receipt, error) {
		t.Fatal("upload entered after launcher timeout")
		return transfer.Receipt{}, nil
	})
	var failure *Error
	if !errors.Is(err, context.DeadlineExceeded) || !errors.Is(err, syscall.EIO) || !errors.As(err, &failure) || failure.Phase != "prepare" {
		t.Fatal(err)
	}
	if calls.Load() != 1 {
		t.Fatal(calls.Load())
	}
}

// delayPublishedFrame models a write whose bytes reached the peer before the
// goroutine gets scheduled to return. The old stage must not invalidate ready.
type delayPublishedFrame struct {
	net.Conn
	phase string
	delay time.Duration
}

func (c *delayPublishedFrame) Write(p []byte) (int, error) {
	n, err := c.Conn.Write(p)
	if err == nil && strings.Contains(string(p), `"phase":"`+c.phase+`"`) {
		time.Sleep(c.delay)
	}
	return n, err
}

func TestPublishedFramesSurvivePreviousStageExpiry(t *testing.T) {
	for _, phase := range []string{"ready", "delivered"} {
		t.Run(phase, func(t *testing.T) {
			// Allow real filesystem syncs on loaded race-test runners. The frame
			// writer still returns after the previous stage's entire budget.
			limits := Timeouts{Prepare: time.Second, Upload: 5 * time.Second, Verify: time.Second, Cleanup: 5 * time.Second}
			if phase == "ready" {
				limits.Verify = 5 * time.Second
			} else {
				limits.Prepare = 5 * time.Second
			}
			c, root := transactionClient(t, limits)
			c.launch = scriptedLauncher(func(ctx context.Context, server net.Conn) {
				connection := &delayPublishedFrame{Conn: server, phase: phase, delay: 1200 * time.Millisecond}
				_ = Serve(ctx, connection, connection)
			})
			// In the delivered case the client may send cleanup immediately, while
			// the server is delayed past the verification deadline before returning.
			result, err := c.Upload(t.Context(), "running.cfg", "device.cfg", writeUpload(root))
			if err != nil || !result.Receipt.Complete() {
				t.Fatalf("result=%+v err=%v", result, err)
			}
		})
	}
}

type slowReadyWriter struct {
	net.Conn
	delay time.Duration
}

func (c *slowReadyWriter) Write(p []byte) (int, error) {
	if strings.Contains(string(p), `"phase":"ready"`) {
		time.Sleep(c.delay)
	}
	return c.Conn.Write(p)
}

func TestSlowReadyTransmissionDoesNotConsumeUploadWindow(t *testing.T) {
	c, root := transactionClient(t, Timeouts{Prepare: time.Second, Upload: 200 * time.Millisecond, Verify: time.Second})
	c.launch = scriptedLauncher(func(ctx context.Context, server net.Conn) {
		connection := &slowReadyWriter{Conn: server, delay: 150 * time.Millisecond}
		_ = serve(ctx, connection, connection, 20*time.Millisecond)
	})
	result, err := c.Upload(t.Context(), "running.cfg", "device.cfg", func(ctx context.Context, name string) (transfer.Receipt, error) {
		time.Sleep(150 * time.Millisecond)
		return writeUpload(root)(ctx, name)
	})
	if err != nil || !result.Receipt.Complete() {
		t.Fatalf("result=%+v err=%v", result, err)
	}
}

type failedStageDeadline struct {
	net.Conn
	calls   int
	failure error
}

func (c *failedStageDeadline) SetReadDeadline(deadline time.Time) error {
	c.calls++
	if c.calls == 2 {
		return c.failure
	}
	return c.Conn.SetReadDeadline(deadline)
}
func TestWorkerStageDeadlineFailureDoesNotWaitForStoppedCallback(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	sentinel := errors.New("deadline setter failed")
	connection := &failedStageDeadline{Conn: server, failure: sentinel}
	done := make(chan error, 1)
	go func() { defer server.Close(); done <- Serve(t.Context(), connection, connection) }()
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	budgets := TimeoutBudget{Prepare: 1000, Upload: 1000, Verify: 1000, Cleanup: 1000}
	protocol := NewProtocol(client, client)
	if err := protocol.Send(ctx, Request{Root: t.TempDir(), Filename: "running.cfg", ArchiveName: "device.cfg", Batch: "2026-11-07", Timeouts: &budgets}); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if !errors.Is(err, sentinel) {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal("worker waited on an already stopped callback")
	}
}

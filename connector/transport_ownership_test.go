package connector

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gatework/go-expect"
	"github.com/gatework/net-connector/storage"
)

// Cancel exactly when Start has acquired a child, without a timing-dependent
// sleep or a production hook that changes process creation.
type cancelAfterStartContext struct {
	context.Context
	command *exec.Cmd
	cancel  context.CancelFunc
}

func (c *cancelAfterStartContext) Err() error {
	if c.command.Process != nil {
		c.cancel()
	}
	return c.Context.Err()
}

func TestProcessCancellationReturnsCleanupOwner(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	command := exec.Command("/bin/sh", "-c", "read value")
	p, err := startProcess(&cancelAfterStartContext{ctx, command, cancel}, command)
	if p != nil {
		defer p.Close()
	}
	if !errors.Is(err, context.Canceled) || p == nil {
		t.Fatalf("canceled startup lost owner: owner=%t err=%v", p != nil, err)
	}
	if err := p.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-p.done:
	default:
		t.Fatal("partial owner's child was not reaped")
	}
}

func authenticateTransport(ctx context.Context, p *processTransport) error {
	return p.Authenticated(ctx)
}

func TestProcessCloseStopsAuthentication(t *testing.T) {
	p, err := startProcess(t.Context(), exec.Command("/bin/sh", "-c", "read value"))
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	p.trust, err = newHostTrust(t.Context(), ConnectionConfig{Host: "fixture", KnownHosts: filepath.Join(t.TempDir(), "known_hosts"), HostKeyPolicy: "strict"}, 22)
	if err != nil {
		t.Fatal(err)
	}
	directory := p.trust.directory
	if err := p.Close(); err != nil {
		t.Fatal(err)
	}
	if err := authenticateTransport(t.Context(), p); !errors.Is(err, ErrClosed) {
		t.Fatalf("authentication admitted after Close: %v", err)
	}
	if _, err := os.Stat(directory); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("trust directory remains: %v", err)
	}
}

type authenticationStream struct {
	net.Conn
	commit func(context.Context) error
}

func (s *authenticationStream) Authenticated(ctx context.Context) error { return s.commit(ctx) }

func TestAuthenticationReceivesOperationContext(t *testing.T) {
	entered := make(chan struct{})
	a, peer := net.Pipe()
	stream := &authenticationStream{Conn: a, commit: func(ctx context.Context) error {
		close(entered)
		<-ctx.Done()
		return ctx.Err()
	}}
	d, err := New(fixtureDriver(), ConnectionConfig{Host: "fixture"}, WithTransportFactory(func(context.Context, ConnectionConfig) (io.ReadWriteCloser, error) { return stream, nil }))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { d.Close(); peer.Close() })
	go io.WriteString(peer, "sw#")
	done := make(chan error, 1)
	go func() { done <- d.Connect(t.Context()) }()
	select {
	case <-entered:
	case err := <-done:
		t.Fatalf("authentication hook was skipped: %v", err)
	}
	if err := d.Close(); err != nil {
		t.Fatal(err)
	}
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("lost cancellation: %v", err)
	}
}

func TestWriteFailureKeepsCompleteTree(t *testing.T) {
	primary := errors.New("private-primary")
	cleanup := errors.New("private-cleanup")
	classified := newError("device_write_failed", "command", Command{Source: "fixture", Line: 7}, primary)
	progress := &expect.WriteError{Written: 3, Cause: errors.Join(classified, context.Canceled, cleanup)}
	err := writeFailure("command", Command{}, progress)
	var written *expect.WriteError
	var metadata *Error
	if !errors.As(err, &written) || written.Written != 3 || !errors.Is(err, primary) || !errors.Is(err, cleanup) || !errors.Is(err, context.Canceled) {
		t.Fatalf("write error tree was truncated: %v", err)
	}
	if !errors.As(err, &metadata) || metadata.Code != "device_write_failed" || metadata.Source != "fixture" || metadata.Line != 7 {
		t.Fatalf("classification changed: %v", err)
	}
	if strings.Contains(fmt.Sprintf("%v %+v %#v", err, err, err), "private-") {
		t.Fatal("diagnostics exposed causes")
	}
}

type partialFailureStream struct {
	net.Conn
	writes, failAt int
	failure        error
}

func (s *partialFailureStream) Write(data []byte) (int, error) {
	s.writes++
	if s.writes != s.failAt {
		return s.Conn.Write(data)
	}
	n, err := s.Conn.Write(data[:3])
	return n, errors.Join(s.failure, err)
}

func TestCommandAndInteractionKeepWriteProgress(t *testing.T) {
	for _, interaction := range []bool{false, true} {
		t.Run(fmt.Sprintf("interaction=%v", interaction), func(t *testing.T) {
			primary, secondary := errors.New("private-primary"), errors.New("private-secondary")
			a, peer := net.Pipe()
			stream := &partialFailureStream{Conn: a, failAt: 1, failure: errors.Join(newError("fixture_write", "command", Command{}, primary), context.Canceled, secondary)}
			profile := fixtureDriver()
			if interaction {
				stream.failAt = 2
				profile.Grammar.Pager, profile.Grammar.PagerResponse = testPattern(`--More--`), "next"
			}
			d, err := New(profile, ConnectionConfig{Host: "fixture"}, WithTransportFactory(func(context.Context, ConnectionConfig) (io.ReadWriteCloser, error) { return stream, nil }))
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { d.Close(); peer.Close() })
			done := make(chan error, 1)
			go func() {
				_, err := io.WriteString(peer, "sw#")
				if err == nil && interaction {
					_, err = io.ReadFull(peer, make([]byte, len("show\n")))
					if err == nil {
						_, err = io.WriteString(peer, "output\n--More--")
					}
				}
				if err == nil {
					_, err = io.ReadFull(peer, make([]byte, 3))
				}
				done <- err
			}()
			result, err := d.ExecuteCommand(t.Context(), Command{Text: "show"}, ExecuteOptions{})
			var progress *expect.WriteError
			if !errors.As(err, &progress) || progress.Written != 3 || !errors.Is(err, primary) || !errors.Is(err, secondary) || !errors.Is(err, context.Canceled) {
				t.Fatalf("lost write tree: %v", err)
			}
			wantWritten := 3
			if interaction {
				wantWritten = len("show\n")
			}
			attempts := result.Attempts()
			if len(result.Steps()) != 0 || len(attempts) != 1 || attempts[0].Written() != wantWritten || attempts[0].Complete() {
				t.Fatalf("wrong attempts: %v", attempts)
			}
			if interaction && !strings.Contains(attempts[0].Response().Raw(), "output") {
				t.Fatal("partial response lost")
			}
			if err := <-done; err != nil {
				t.Fatal(err)
			}
		})
	}
}

func candidateTrust(t *testing.T) *hostTrust {
	t.Helper()
	directory := t.TempDir()
	key := filepath.Join(directory, "key")
	if b, err := exec.Command("ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key).CombinedOutput(); err != nil {
		t.Fatalf("key fixture: %v %s", err, b)
	}
	public, err := os.ReadFile(key + ".pub")
	if err != nil {
		t.Fatal(err)
	}
	trust, err := newHostTrust(t.Context(), ConnectionConfig{Host: "fixture", KnownHosts: filepath.Join(directory, "known_hosts"), HostKeyPolicy: "accept_new"}, 22)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = trust.close() })
	if err := os.WriteFile(trust.snapshot, append([]byte("fixture "), public...), 0600); err != nil {
		t.Fatal(err)
	}
	return trust
}

func TestTrustCloseCancelsAndJoinsCommitBeforeRemoval(t *testing.T) {
	trust := candidateTrust(t)
	entered, canceled, release := make(chan struct{}), make(chan struct{}), make(chan struct{})
	defer close(release)
	trust.write = func(ctx context.Context, path string, data []byte) (storage.Receipt, error) {
		close(entered)
		<-ctx.Done()
		close(canceled)
		<-release
		return storage.Write(ctx, path, data)
	}
	p, err := startProcess(t.Context(), exec.Command("/bin/sh", "-c", "read value"))
	if err != nil {
		t.Fatal(err)
	}
	p.trust = trust
	commit := make(chan error, 1)
	go func() { commit <- p.Authenticated(t.Context()) }()
	<-entered
	read := make(chan error, 1)
	go func() { _, err := p.Read(make([]byte, 1)); read <- err }()
	closed := make(chan error, 1)
	go func() { closed <- p.Close() }()
	<-canceled
	select {
	case <-read:
	case <-time.After(3 * time.Second):
		t.Fatal("Close waited for trust before interrupting I/O")
	}
	if _, err := os.Stat(trust.snapshot); err != nil {
		t.Fatalf("snapshot removed while still in use: %v", err)
	}
	select {
	case err := <-closed:
		t.Fatalf("Close returned before owned commit exited: %v", err)
	default:
	}
	// Release before waiting, but keep the failure path's deferred release too.
	release <- struct{}{}
	if err := <-commit; !errors.Is(err, context.Canceled) {
		t.Fatalf("lost commit cancellation: %v", err)
	}
	if err := <-closed; err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(trust.directory); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("temporary trust remains: %v", err)
	}
	if _, err := os.Stat(trust.destination); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("canceled commit wrote shared trust: %v", err)
	}
}

func TestTrustCommitKeepsDurabilityReceipt(t *testing.T) {
	trust := candidateTrust(t)
	brokenSync := errors.New("private directory sync failure")
	trust.write = func(ctx context.Context, path string, data []byte) (storage.Receipt, error) {
		receipt, err := storage.Write(ctx, path, data)
		if err != nil {
			return receipt, err
		}
		receipt.State, receipt.Phase = storage.StateCommitted, "directory_sync"
		return receipt, &storage.WriteError{Receipt: receipt, Cause: brokenSync}
	}
	err := trust.commit(t.Context())
	var written *storage.WriteError
	if !errors.Is(err, brokenSync) || !errors.As(err, &written) || !written.Receipt.Committed() {
		t.Fatalf("lost receipt: %v", err)
	}
	if err := trust.close(); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(trust.destination); err != nil || !strings.HasPrefix(string(data), "fixture ssh-ed25519 ") {
		t.Fatalf("committed trust was rolled back: %v", err)
	}
}

func TestCanceledProcessCleanupFailureStaysOwned(t *testing.T) {
	trust := candidateTrust(t)
	cleanup := errors.New("private trust cleanup failure")
	calls := 0
	trust.removeDirectory = func(path string) error {
		calls++
		if calls < 3 {
			return cleanup
		}
		return os.RemoveAll(path)
	}
	d, err := New(fixtureDriver(), ConnectionConfig{Host: "fixture"}, WithTransportFactory(func(ctx context.Context, _ ConnectionConfig) (io.ReadWriteCloser, error) {
		ctx, cancel := context.WithCancel(ctx)
		defer cancel()
		cmd := exec.Command("/bin/sh", "-c", "read value")
		p, err := startProcess(&cancelAfterStartContext{ctx, cmd, cancel}, cmd) //nolint:contextcheck // The wrapper embeds ctx and injects cancellation after process start.
		if p != nil {
			p.trust = trust
		}
		return p, err
	}))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = d.Close() })
	if err := d.Connect(t.Context()); !errors.Is(err, context.Canceled) || !errors.Is(err, cleanup) {
		t.Fatalf("lost setup/cleanup errors: %v", err)
	}
	if calls != 2 {
		t.Fatalf("cleanup owner lost: calls=%d", calls)
	}
	if err := d.Close(); err != nil {
		t.Fatal(err)
	}
	if err := d.Close(); err != nil {
		t.Fatal(err)
	}
	if calls != 3 {
		t.Fatalf("successful cleanup was repeated: calls=%d", calls)
	}
}

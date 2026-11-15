//go:build linux || darwin

package connector

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gatework/net-connector/storage"
)

type hostTrust struct {
	mu                                     sync.Mutex
	cleanupMu                              sync.Mutex
	closing, removed                       bool
	commitCancel                           context.CancelFunc
	commitDone                             chan struct{}
	write                                  func(context.Context, string, []byte) (storage.Receipt, error)
	removeDirectory                        func(string) error
	destination, snapshot, directory, host string
	policy                                 HostKeyPolicy
	original                               []string
}

func newHostTrust(ctx context.Context, cfg ConnectionConfig, port int) (*hostTrust, error) {
	destination := cfg.KnownHosts
	if destination == "" {
		home, e := os.UserHomeDir()
		if e != nil {
			return nil, e
		}
		destination = filepath.Join(home, ".ssh", "known_hosts")
	}
	absolute, e := filepath.Abs(destination)
	if e != nil {
		return nil, e
	}
	b, _, e := storage.Read(ctx, absolute, 4<<20)
	if e != nil && !errors.Is(e, os.ErrNotExist) {
		return nil, e
	}
	dir, e := os.MkdirTemp("", "net-connector-hostkeys-")
	if e != nil {
		return nil, e
	}
	target := cfg.Host
	if port != 22 {
		target = "[" + cfg.Host + "]:" + strconv.Itoa(port)
	}
	t := &hostTrust{write: storage.Write, removeDirectory: os.RemoveAll, destination: absolute, snapshot: filepath.Join(dir, "known_hosts"), directory: dir, host: target, policy: cfg.HostKeyPolicy}
	if e = os.WriteFile(t.snapshot, b, 0600); e != nil {
		return t, e
	}
	t.original, e = t.keys(ctx, t.snapshot)
	if e != nil {
		return t, e
	}
	if cfg.replaceHostKey {
		if e = t.remove(ctx, t.snapshot); e != nil {
			return t, e
		}
	}
	return t, nil
}
func (t *hostTrust) keys(ctx context.Context, path string) ([]string, error) {
	output, e := exec.CommandContext(ctx, "ssh-keygen", "-F", t.host, "-f", path).Output() //nolint:gosec // host and path are validated connector configuration
	if e != nil {
		var status *exec.ExitError
		if ctx.Err() == nil && errors.As(e, &status) && status.ExitCode() == 1 {
			return nil, nil
		}
		return nil, newError("host_key_lookup_failed", "login", Command{}, errors.Join(ctx.Err(), e))
	}
	var keys []string
	for line := range strings.SplitSeq(string(output), "\n") {
		if line != "" && !strings.HasPrefix(line, "#") {
			keys = append(keys, line)
		}
	}
	return keys, nil
}
func (t *hostTrust) remove(ctx context.Context, path string) error {
	if e := exec.CommandContext(ctx, "ssh-keygen", "-R", t.host, "-f", path).Run(); e != nil { //nolint:gosec // host and path are validated connector configuration
		return newError("host_key_update_failed", "login", Command{}, errors.Join(ctx.Err(), e))
	}
	return nil
}

// commit owns the temporary snapshot until it returns. Close may cancel it,
// but cannot remove the snapshot or merged file while they are still in use.
func (t *hostTrust) commit(parent context.Context) (err error) {
	if err = parent.Err(); err != nil {
		return err
	}
	t.mu.Lock()
	if t.closing {
		t.mu.Unlock()
		return ErrClosed
	}
	if t.commitDone != nil {
		t.mu.Unlock()
		return ErrBusy
	}
	ctx, cancel := context.WithCancel(parent)
	done := make(chan struct{})
	t.commitCancel, t.commitDone = cancel, done
	t.mu.Unlock()
	defer func() {
		err = errors.Join(err, ctx.Err())
		cancel()
		t.mu.Lock()
		t.commitCancel, t.commitDone = nil, nil
		close(done)
		t.mu.Unlock()
	}()
	return t.persist(ctx)
}

func (t *hostTrust) persist(ctx context.Context) (err error) {
	if t.policy == HostKeyStrict {
		return nil
	}
	candidate, e := t.keys(ctx, t.snapshot)
	if e != nil {
		return e
	}
	if len(candidate) == 0 {
		return errors.New("connector: authenticated host has no key evidence")
	}
	if e = os.MkdirAll(filepath.Dir(t.destination), 0700); e != nil {
		return e
	}
	lock, e := storage.Acquire(ctx, t.destination, 5*time.Second)
	if e != nil {
		return e
	}
	defer func() { err = errors.Join(err, lock.Close()) }()
	current, _, e := storage.Read(ctx, t.destination, 4<<20)
	if e != nil && !errors.Is(e, os.ErrNotExist) {
		return e
	}
	merged := filepath.Join(t.directory, "merged")
	if e = os.WriteFile(merged, current, 0600); e != nil {
		return e
	}
	currentKeys, e := t.keys(ctx, merged)
	if e != nil {
		return e
	}
	if strings.Join(currentKeys, "\n") != strings.Join(t.original, "\n") && strings.Join(currentKeys, "\n") != strings.Join(candidate, "\n") {
		return errors.New("connector: concurrent host key conflict")
	}
	if strings.Join(currentKeys, "\n") == strings.Join(candidate, "\n") {
		return nil
	}
	if len(currentKeys) > 0 {
		if e = t.remove(ctx, merged); e != nil {
			return e
		}
		current, e = os.ReadFile(merged)
		if e != nil {
			return e
		}
	}
	if len(current) > 0 && current[len(current)-1] != '\n' {
		current = append(current, '\n')
	}
	current = append(current, []byte(strings.Join(candidate, "\n")+"\n")...)
	_, e = t.write(ctx, t.destination, current)
	return e
}

// stop closes admission before publishing cancellation. The caller must join
// the returned completion channel separately; cancellation itself does not join.
func (t *hostTrust) stop() <-chan struct{} {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.closing = true
	if t.commitCancel != nil {
		t.commitCancel()
	}
	return t.commitDone
}
func (t *hostTrust) close() error {
	if done := t.stop(); done != nil {
		<-done
	}
	t.cleanupMu.Lock()
	defer t.cleanupMu.Unlock()
	if t.removed {
		return nil
	}
	if err := t.removeDirectory(t.directory); err != nil {
		return err
	}
	t.removed = true
	return nil
}

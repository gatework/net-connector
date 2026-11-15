//go:build linux || darwin

package connector

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"slices"

	"golang.org/x/sys/unix"
	"golang.org/x/term"

	expect "github.com/gatework/go-expect"
	"github.com/gatework/net-connector/internal/nilcheck"
)

// InteractOptions borrows a file input and cooperative output. Input must have
// no competing reader for the duration of the call. Empty Escape disables it.
type InteractOptions struct {
	Input   *os.File
	Output  io.Writer
	Escape  []byte
	SkipRaw bool
}

// InteractResult records why interaction ended and input remaining after an escape.
type InteractResult struct {
	Reason       string
	PendingInput []byte
}
type inputResult struct {
	reason  string
	pending []byte
	err     error
}

// Interact relays borrowed terminal input and output while owning the device lease.
func (d *Device) Interact(parent context.Context, o InteractOptions) (result InteractResult, err error) {
	if o.Input == nil || nilcheck.IsNil(o.Output) {
		return result, ErrInvalid
	}
	if e := d.acquire(); e != nil {
		return result, e
	}
	defer d.release()
	parent, stopOperation := d.operationContext(parent)
	defer stopOperation()
	if err = d.connect(parent); err != nil {
		return
	}
	if err = d.log.scope(d.baseSecrets(), true); err != nil {
		return
	}
	fd := int(o.Input.Fd())
	if !o.SkipRaw && term.IsTerminal(fd) {
		state, e := term.MakeRaw(fd)
		if e != nil {
			return result, e
		}
		defer func() {
			err = joinCleanup(err, term.Restore(fd, state))
		}()
	}
	ctx, cancel := context.WithCancel(parent)
	defer cancel()
	done := make(chan inputResult, 1)
	escape := slices.Clone(o.Escape)
	session := d.session
	go func() { r := d.relayInput(ctx, session, fd, escape); done <- r; cancel() }()
	returned := false
	defer func() {
		if !returned {
			cancel()
			_ = d.closeResources()
			<-done
		}
	}()
	pattern, _ := expect.Compile(`(?s).+`)
	_, readErr := d.session.Expect(ctx, []expect.Case{{Pattern: pattern, Handler: interactionOutput(o.Output)}, {Pattern: expect.EOF()}}, expect.WithTimeout(0))
	cancel()
	cleanupErr := d.closeResources()
	defer func() { err = joinCleanup(err, cleanupErr) }()
	input := <-done
	returned = true
	return finishInteraction(parent, readErr, input)
}

// finishInteraction prioritizes caller cancellation, then remote and local errors.
func finishInteraction(parent context.Context, readErr error, input inputResult) (InteractResult, error) {
	result := InteractResult{Reason: input.reason, PendingInput: slices.Clone(input.pending)}
	if e := parent.Err(); e != nil {
		return result, e
	}
	if readErr != nil && !errors.Is(readErr, context.Canceled) && !errors.Is(readErr, io.EOF) {
		return result, newError("interaction_failed", "interact", Command{}, readErr)
	}
	if input.err != nil && !errors.Is(input.err, context.Canceled) && !errors.Is(input.err, expect.ErrClosed) {
		return result, newError("interaction_failed", "interact", Command{}, input.err)
	}
	if result.Reason == "" {
		result.Reason = "peer_eof"
	}
	return result, nil
}

// interactionOutput forwards each accepted response once to the borrowed writer.
func interactionOutput(output io.Writer) expect.Handler {
	return func(_ context.Context, _ *expect.Session, r expect.Result) (expect.Action, error) {
		p := []byte(r.Before + r.Match)
		n, e := output.Write(p)
		if e == nil && n != len(p) {
			e = io.ErrShortWrite
		}
		return expect.ContinueKeepTimer, e
	}
}

func (d *Device) relayInput(ctx context.Context, session *expect.Session, fd int, escape []byte) inputResult {
	r := interactionRelay{session: session, escape: escape}
	buffer := make([]byte, 4096)
	for {
		if e := ctx.Err(); e != nil {
			return inputResult{err: e, pending: r.pending}
		}
		n, retry, err := readInteractionInput(fd, buffer)
		if retry {
			continue
		}
		if err != nil {
			return inputResult{err: err, pending: r.pending}
		}
		if n == 0 {
			return r.finish(ctx)
		}
		if result, done := r.forward(ctx, buffer[:n]); done {
			return result
		}
	}
}

// readInteractionInput polls the borrowed descriptor, then reads once. retry
// covers readiness timeouts and interrupted or temporarily unavailable reads.
func readInteractionInput(fd int, buffer []byte) (n int, retry bool, err error) {
	poll := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLIN}}
	n, err = unix.Poll(poll, 10)
	if errors.Is(err, unix.EINTR) {
		return 0, true, nil
	}
	if err != nil {
		return 0, false, err
	}
	if n == 0 {
		return 0, true, nil
	}
	if poll[0].Revents&unix.POLLNVAL != 0 {
		return 0, false, os.ErrInvalid
	}
	n, err = unix.Read(fd, buffer)
	if errors.Is(err, unix.EINTR) || errors.Is(err, unix.EAGAIN) {
		return 0, true, nil
	}
	return n, false, err
}

// interactionRelay retains an escape prefix between local input reads.
type interactionRelay struct {
	session *expect.Session
	escape  []byte
	pending []byte
}

func (r *interactionRelay) finish(ctx context.Context) inputResult {
	if len(r.pending) > 0 {
		if _, err := r.session.SendAll(ctx, string(r.pending)); err != nil {
			return inputResult{err: err}
		}
	}
	return inputResult{reason: "input_eof"}
}

func (r *interactionRelay) forward(ctx context.Context, data []byte) (inputResult, bool) {
	r.pending = append(r.pending, data...)
	send := len(r.pending)
	if len(r.escape) > 0 {
		if i := bytes.Index(r.pending, r.escape); i >= 0 {
			if i > 0 {
				if _, err := r.session.SendAll(ctx, string(r.pending[:i])); err != nil {
					return inputResult{err: err, pending: r.pending}, true
				}
			}
			return inputResult{reason: "escape", pending: r.pending[i+len(r.escape):]}, true
		}
		for retain := min(len(r.pending), len(r.escape)-1); retain > 0; retain-- {
			if bytes.Equal(r.pending[len(r.pending)-retain:], r.escape[:retain]) {
				send -= retain
				break
			}
		}
	}
	if send > 0 {
		if _, err := r.session.SendAll(ctx, string(r.pending[:send])); err != nil {
			return inputResult{err: err, pending: r.pending}, true
		}
		r.pending = append(r.pending[:0], r.pending[send:]...)
	}
	return inputResult{}, false
}

// Package transport opens interactive byte streams to devices. It knows
// nothing about prompts or vendors: an implementation delivers an
// io.ReadWriteCloser connected to the device's CLI, and package terminal
// holds the conversation.
//
// Errors carry netops failure codes: CodeUnreachable and CodeTimeout for
// connection failures (retryable), CodeHostKey for an untrusted host key
// and CodeAuth for refused credentials (never retried).
package transport

import (
	"context"
	"errors"
	"io"
	"net"
	"strconv"
	"time"

	"github.com/gatework/netops/failure"
	"github.com/gatework/netops/secret"
)

// Target is the management address of a device.
type Target struct {
	Host string // address or name
	Port int    // zero uses the protocol default
}

// Address returns "host:port".
func (t Target) Address(defaultPort int) string {
	p := t.Port
	if p == 0 {
		p = defaultPort
	}
	return net.JoinHostPort(t.Host, strconv.Itoa(p))
}

// Auth is what the transport authenticates with.
type Auth struct {
	Username     string
	Password     secret.Secret
	IdentityFile string
	Passphrase   secret.Secret
}

// Window is the terminal size requested from the device.
type Window struct {
	Width, Height int
	Type          string // "vt100" when empty
}

// Dialer opens interactive streams.
type Dialer interface {
	Dial(ctx context.Context, t Target, a Auth, w Window) (io.ReadWriteCloser, error)
}

// Retrying retries connection failures that happen before authentication:
// refused, unreachable or timed out. Authentication and host key failures
// are returned at once, so a wrong password is never repeated.
type Retrying struct {
	Dialer
	// Retries is the number of extra attempts; at most 5.
	Retries int
	// Backoff is the wait before the first retry, growing linearly; zero
	// means one second.
	Backoff time.Duration
}

// Dial dials with retries.
func (r Retrying) Dial(ctx context.Context, t Target, a Auth, w Window) (io.ReadWriteCloser, error) {
	wait := r.Backoff
	if wait <= 0 {
		wait = time.Second
	}
	for attempt := 0; ; attempt++ {
		s, err := r.Dialer.Dial(ctx, t, a, w)
		if err == nil || attempt >= min(r.Retries, 5) || !Retryable(err) {
			return s, err
		}
		select {
		case <-ctx.Done():
			return nil, failure.Wrap(failure.CodeCancelled, "transport: dial", ctx.Err())
		case <-time.After(wait * time.Duration(attempt+1)):
		}
	}
}

// Retryable reports whether err is a connection failure that happened
// before any credential was sent.
func Retryable(err error) bool {
	code := failure.Primary(err)
	return code == failure.CodeUnreachable || code == failure.CodeTimeout
}

// Classify maps a network error to a failure code.
func Classify(op string, err error) error {
	if err == nil {
		return nil
	}
	var coded failure.Coded
	if errors.As(err, &coded) {
		return err
	}
	code := failure.CodeUnreachable
	if ne, ok := errors.AsType[net.Error](err); ok && ne.Timeout() {
		code = failure.CodeTimeout
	}
	switch {
	case errors.Is(err, context.Canceled):
		code = failure.CodeCancelled
	case errors.Is(err, context.DeadlineExceeded):
		code = failure.CodeTimeout
	}
	return failure.Wrap(code, op, err)
}

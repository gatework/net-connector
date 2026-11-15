package archive

import (
	"context"
	"errors"
	"io"
	"time"

	"github.com/gatework/net-connector/internal/nilcheck"
)

// Channel owns the bidirectional worker stream and its cleanup callbacks.
type Channel struct {
	Input  io.Writer
	Output io.Reader
	Close  func() error
}

// Launcher transfers ownership of a nonzero Channel even when it also returns an error.
type Launcher func(context.Context) (Channel, error)

// runChannel owns a launched channel, including partial returns with an error.
func runChannel(ctx context.Context, launch Launcher, run func(*Protocol) error, retain func(func() error)) (err error) {
	if err := ctx.Err(); err != nil {
		return err
	}
	ch, e := launch(ctx)
	closeChannel := func() error {
		err := ch.Close()
		if err != nil && retain != nil {
			retain(ch.Close)
		}
		return err
	}
	if e != nil {
		if ch.Close != nil {
			e = errors.Join(e, closeChannel())
		}
		return channelFailure(e)
	}
	if ch.Close != nil {
		defer func() {
			if joined := errors.Join(err, closeChannel()); joined != nil {
				err = channelFailure(joined)
			}
		}()
	}
	if ch.Close == nil || nilcheck.IsNil(ch.Input) || nilcheck.IsNil(ch.Output) {
		return ErrArchive
	}
	input, ok := ch.Input.(interface{ SetWriteDeadline(t time.Time) error })
	if !ok {
		return ErrArchive
	}
	output, ok := ch.Output.(interface{ SetReadDeadline(t time.Time) error })
	if !ok {
		return ErrArchive
	}
	// Verify actual deadline support before any protocol bytes are exchanged.
	deadline := time.Now().Add(time.Second)
	for _, set := range []func(time.Time) error{input.SetWriteDeadline, output.SetReadDeadline} {
		if err := set(deadline); err != nil {
			return &Error{cause: errors.Join(ErrArchive, err)}
		}
	}
	for _, set := range []func(time.Time) error{input.SetWriteDeadline, output.SetReadDeadline} {
		if err := set(time.Time{}); err != nil {
			return &Error{cause: errors.Join(ErrArchive, err)}
		}
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	return run(NewProtocol(ch.Input, ch.Output))
}

func channelFailure(cause error) error {
	phase := ""
	if primary, ok := errors.AsType[*Error](cause); ok {
		phase = primary.Phase
	}
	return &Error{Phase: phase, cause: cause}
}

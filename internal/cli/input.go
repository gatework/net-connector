package cli

import (
	"context"
	"errors"
	"io"
	"os"
	"unicode/utf8"

	"golang.org/x/term"

	"github.com/gatework/net-connector/config"

	"golang.org/x/sys/unix"
)

// contextReader makes reads of a terminal observe cancellation.
type contextReader struct {
	ctx context.Context //nolint:containedctx // an io.Reader adapter cannot take ctx per Read
	in  io.Reader
}

func contextInput(ctx context.Context, in io.Reader) io.Reader {
	return contextReader{ctx: ctx, in: in}
}

// Poll caller-owned descriptors; cancellation never abandons a blocked goroutine.
func (r contextReader) Read(b []byte) (int, error) {
	if len(b) == 0 {
		return 0, nil
	}
	if f, ok := r.in.(*os.File); ok {
		p := []unix.PollFd{{Fd: int32(f.Fd()), Events: unix.POLLIN}}
		for {
			if err := r.ctx.Err(); err != nil {
				return 0, err
			}
			n, err := unix.Poll(p, 100)
			if errors.Is(err, unix.EINTR) {
				continue
			}
			if err != nil {
				return 0, err
			}
			if n > 0 {
				break
			}
		}
	}
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.in.Read(b)
}

func readTerminalSecret(ctx context.Context, in *os.File) (string, error) {
	state, err := term.MakeRaw(int(in.Fd()))
	if err != nil {
		return "", err
	}
	defer func() { _ = term.Restore(int(in.Fd()), state) }()
	reader := contextInput(ctx, in)
	value := make([]byte, 0, 128)
	for len(value) <= 64<<10 {
		var b [1]byte
		if _, err := io.ReadFull(reader, b[:]); err != nil {
			return "", err
		}
		switch b[0] {
		case 3:
			return "", context.Canceled
		case 4:
			return "", io.EOF
		case '\r', '\n':
			return string(value), nil
		case 8, 127:
			if len(value) > 0 {
				_, n := utf8.DecodeLastRune(value)
				value = value[:len(value)-n]
			}
		default:
			value = append(value, b[0])
		}
	}
	return "", config.ErrInvalid
}

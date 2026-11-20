package connectortest

import (
	"context"
	"io"
	"sync"
	"testing"

	"github.com/gatework/net-connector/transport"
)

// Dialer is a transport.Dialer that serves one script per Dial, in order.
type Dialer struct {
	tb      testing.TB
	mu      sync.Mutex
	scripts [][]Step
	// Auth records the credentials of each Dial.
	Auth []transport.Auth
}

var _ transport.Dialer = (*Dialer)(nil)

// NewDialer returns a dialer for scripts.
func NewDialer(tb testing.TB, scripts ...[]Step) *Dialer {
	tb.Helper()
	return &Dialer{tb: tb, scripts: scripts}
}

// Dial starts the next script.
func (d *Dialer) Dial(_ context.Context, _ transport.Target, a transport.Auth, _ transport.Window) (io.ReadWriteCloser, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.Auth = append(d.Auth, a)
	if len(d.scripts) == 0 {
		d.tb.Error("connectortest: unexpected dial")
		return nil, io.ErrUnexpectedEOF
	}
	s := d.scripts[0]
	d.scripts = d.scripts[1:]
	stream, _ := Start(d.tb, s...)
	return stream, nil
}

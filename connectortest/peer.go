package connectortest

import (
	"bytes"
	"fmt"
	"io"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

// Step is one turn of a scripted device. When Want is set the device first
// reads exactly those bytes; then it sends Send. Close ends the stream
// after Send.
type Step struct {
	Want  string
	Send  string
	Close bool
}

// Send returns a step that only sends.
func Send(s string) Step { return Step{Send: s} }

// Reply returns a step that reads want and answers send.
func Reply(want, send string) Step { return Step{Want: want, Send: send} }

// Hangup returns a step that reads want and closes the stream.
func Hangup(want string) Step { return Step{Want: want, Close: true} }

// Device is a running fake device.
type Device struct {
	tb     testing.TB
	conn   net.Conn
	done   chan struct{}
	mu     sync.Mutex
	err    error
	steps  int
	total  int
	stream *bytes.Buffer
}

// Start runs script on one end of an in-memory pipe and returns the other
// end for the code under test. At cleanup it fails tb unless the whole
// script ran and every byte matched.
func Start(tb testing.TB, script ...Step) (io.ReadWriteCloser, *Device) {
	tb.Helper()
	client, server := net.Pipe()
	d := &Device{tb: tb, conn: server, done: make(chan struct{}), total: len(script), stream: &bytes.Buffer{}}
	go d.serve(script)
	tb.Cleanup(func() {
		_ = client.Close()
		select {
		case <-d.done:
		case <-time.After(5 * time.Second):
			tb.Error("connectortest: device did not stop")
		}
		if err := d.Err(); err != nil {
			tb.Error(err)
		}
	})
	return client, d
}

// Err returns the first mismatch, or an error when the script did not run
// to the end.
func (d *Device) Err() error {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.err != nil {
		return d.err
	}
	if d.steps < d.total {
		return fmt.Errorf("connectortest: script stopped at step %d of %d", d.steps+1, d.total)
	}
	return nil
}

// Received returns every byte the device read.
func (d *Device) Received() string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.stream.String()
}

func (d *Device) fail(format string, args ...any) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.err == nil {
		d.err = fmt.Errorf(format, args...)
	}
}

func (d *Device) serve(script []Step) {
	defer close(d.done)
	defer func() { _ = d.conn.Close() }()
	for i, st := range script {
		if st.Want != "" {
			got := make([]byte, 0, len(st.Want))
			b := make([]byte, 1)
			for len(got) < len(st.Want) {
				if _, err := d.conn.Read(b); err != nil {
					d.fail("connectortest: step %d: want %q, got %q then %v", i+1, st.Want, got, err)
					return
				}
				got = append(got, b[0])
				d.mu.Lock()
				d.stream.WriteByte(b[0])
				d.mu.Unlock()
				if !strings.HasPrefix(st.Want, string(got)) {
					d.fail("connectortest: step %d: want %q, got %q", i+1, st.Want, got)
					return
				}
			}
		}
		if st.Send != "" {
			if _, err := io.WriteString(d.conn, st.Send); err != nil {
				d.fail("connectortest: step %d: send: %v", i+1, err)
				return
			}
		}
		d.mu.Lock()
		d.steps = i + 1
		d.mu.Unlock()
		if st.Close {
			return
		}
	}
	// Anything the client sends after the script is unexpected.
	rest, _ := io.ReadAll(d.conn)
	if len(rest) > 0 {
		d.fail("connectortest: unexpected bytes after the script: %q", rest)
	}
}

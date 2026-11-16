package archive

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"testing"
	"time"
)

type failedWriter struct{ err error }

// Timer propagation may lag an I/O deadline. The deadline remains authoritative
// even while Err has not yet been published by a context's timer callback.
type delayedDeadlineContext struct {
	context.Context
	deadline time.Time
}

func (c delayedDeadlineContext) Deadline() (time.Time, bool) { return c.deadline, true }

func TestProtocolFailureRetainsElapsedDeadline(t *testing.T) {
	t.Parallel()
	for _, expired := range []bool{false, true} {
		deadline := time.Now().Add(time.Hour)
		if expired {
			deadline = time.Now().Add(-time.Second)
		}
		ctx := delayedDeadlineContext{Context: t.Context(), deadline: deadline}
		err := protocolFailure(ctx, io.EOF)
		if !errors.Is(err, io.EOF) || errors.Is(err, context.DeadlineExceeded) != expired {
			t.Fatalf("expired=%t: lost EOF/deadline evidence: %v", expired, err)
		}
	}
}

func (w failedWriter) Write([]byte) (int, error) { return 0, w.err }
func TestProtocolDrainsAfterSinkFailureAndChecksDigest(t *testing.T) {
	c, s := net.Pipe()
	defer c.Close()
	data := []byte("config\x00binary\n")
	go func() {
		defer s.Close()
		json.NewEncoder(s).Encode(map[string]any{"version": Version, "ok": true, "phase": "archived", "bytes": len(data), "sha256": fmt.Sprintf("%x", sha256.Sum256(data)), "archive_path": "/tftp/archive/batch/file"})
		s.Write(data)
		json.NewEncoder(s).Encode(map[string]any{"version": Version, "ok": true, "phase": "delivered"})
	}()
	p := NewProtocol(c, c)
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	proof, e := p.Expect(ctx, "archived")
	if e != nil {
		t.Fatal(e)
	}
	primary := errors.New("disk failed")
	got, e := p.Receive(ctx, proof, failedWriter{primary})
	if !errors.Is(e, primary) || !got.Verified {
		t.Fatal(got, e)
	}
}
func TestProtocolDeadlineDoesNotResetForBodyAndTrailer(t *testing.T) {
	c, s := net.Pipe()
	defer c.Close()
	defer s.Close()
	go func() {
		json.NewEncoder(s).Encode(map[string]any{"version": Version, "ok": true, "phase": "archived", "bytes": 1, "sha256": fmt.Sprintf("%x", sha256.Sum256([]byte("x"))), "archive_path": "/archive/config.cfg"})
		time.Sleep(350 * time.Millisecond)
		s.Write([]byte("x"))
		time.Sleep(300 * time.Millisecond)
		json.NewEncoder(s).Encode(map[string]any{"version": Version, "ok": true, "phase": "delivered"})
	}()
	p := NewProtocol(c, c)
	ctx, cancel := context.WithTimeout(t.Context(), 500*time.Millisecond)
	defer cancel()
	proof, e := p.Expect(ctx, "archived")
	if e != nil {
		t.Fatal(e)
	}
	_, e = p.Receive(ctx, proof, io.Discard)
	if e == nil {
		t.Fatal("deadline reset")
	}
}

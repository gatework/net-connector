// Package telnet is the Telnet transport: a TCP connection with the
// minimal RFC 854 option negotiation a device CLI needs. No widely used Go
// Telnet library exists, so this package keeps the protocol to the
// options devices actually request: it agrees to ECHO and SUPPRESS-GO-AHEAD
// from the server, reports its window size (NAWS) and terminal type, and
// refuses everything else.
package telnet

import (
	"bufio"
	"context"
	"encoding/binary"
	"io"
	"net"
	"sync"
	"time"

	"github.com/gatework/net-connector/transport"
)

// Telnet protocol bytes.
const (
	iac  = 255
	dont = 254
	do   = 253
	wont = 252
	will = 251
	sb   = 250
	se   = 240

	optEcho  = 1
	optSGA   = 3
	optTType = 24
	optNAWS  = 31

	ttypeSend = 1
	ttypeIs   = 0
)

// Options configure the Telnet transport.
type Options struct {
	// Timeout bounds the TCP connect; zero means 30s.
	Timeout time.Duration
}

// Dialer is the Telnet transport.
type Dialer struct{ o Options }

var _ transport.Dialer = Dialer{}

// New returns a Telnet dialer.
func New(o Options) Dialer {
	if o.Timeout <= 0 {
		o.Timeout = 30 * time.Second
	}
	return Dialer{o: o}
}

// Dial connects. Credentials are exchanged in band by the terminal
// session, so a is not used here.
func (d Dialer) Dial(ctx context.Context, t transport.Target, _ transport.Auth, w transport.Window) (io.ReadWriteCloser, error) {
	nd := net.Dialer{Timeout: d.o.Timeout}
	c, err := nd.DialContext(ctx, "tcp", t.Address(23))
	if err != nil {
		return nil, transport.Classify("telnet: connect", err)
	}
	return NewConn(c, w), nil
}

// Conn filters Telnet commands out of a connection's input, answers
// negotiation and escapes IAC in output.
type Conn struct {
	c   net.Conn
	r   *bufio.Reader
	w   transport.Window
	wmu sync.Mutex
}

// NewConn wraps c.
func NewConn(c net.Conn, w transport.Window) *Conn {
	if w.Type == "" {
		w.Type = "vt100"
	}
	return &Conn{c: c, r: bufio.NewReader(c), w: w}
}

// Close closes the connection.
func (c *Conn) Close() error { return c.c.Close() }

// Write sends p, doubling IAC bytes.
func (c *Conn) Write(p []byte) (int, error) {
	esc := make([]byte, 0, len(p))
	for _, b := range p {
		esc = append(esc, b)
		if b == iac {
			esc = append(esc, iac)
		}
	}
	if err := c.send(esc); err != nil {
		return 0, err
	}
	return len(p), nil
}

// Read returns data bytes, handling commands in between. It returns at
// least one byte or an error.
func (c *Conn) Read(p []byte) (int, error) {
	n := 0
	for n == 0 || (n < len(p) && c.r.Buffered() > 0) {
		b, err := c.r.ReadByte()
		if err != nil {
			if n > 0 {
				return n, nil
			}
			return 0, err
		}
		if b != iac {
			p[n] = b
			n++
			continue
		}
		data, err := c.command()
		if err != nil {
			return n, err
		}
		if data {
			p[n] = iac
			n++
		}
	}
	return n, nil
}

func (c *Conn) send(b []byte) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	_, err := c.c.Write(b)
	return err
}

// command handles the bytes after IAC; data reports an escaped 255.
func (c *Conn) command() (data bool, err error) {
	verb, err := c.r.ReadByte()
	if err != nil {
		return false, err
	}
	switch verb {
	case iac:
		return true, nil
	case do, dont, will, wont:
		opt, err := c.r.ReadByte()
		if err != nil {
			return false, err
		}
		return false, c.negotiate(verb, opt)
	case sb:
		return false, c.subnegotiation()
	default: // NOP, GA and other two-byte commands carry no data.
		return false, nil
	}
}

func (c *Conn) negotiate(verb, opt byte) error {
	switch verb {
	case will:
		if opt == optEcho || opt == optSGA {
			return c.send([]byte{iac, do, opt})
		}
		return c.send([]byte{iac, dont, opt})
	case do:
		switch opt {
		case optNAWS:
			if err := c.send([]byte{iac, will, optNAWS}); err != nil {
				return err
			}
			return c.naws()
		case optTType, optSGA:
			return c.send([]byte{iac, will, opt})
		}
		return c.send([]byte{iac, wont, opt})
	}
	return nil // DONT and WONT need no answer for options we never enable.
}

func (c *Conn) naws() error {
	msg := []byte{iac, sb, optNAWS, 0, 0, 0, 0, iac, se}
	binary.BigEndian.PutUint16(msg[3:], uint16(min(max(c.w.Width, 80), 0xfffe)))
	binary.BigEndian.PutUint16(msg[5:], uint16(min(max(c.w.Height, 24), 0xfffe)))
	return c.send(msg)
}

// subnegotiation reads through IAC SE and answers TTYPE SEND.
func (c *Conn) subnegotiation() error {
	var body []byte
	for {
		b, err := c.r.ReadByte()
		if err != nil {
			return err
		}
		if b == iac {
			next, err := c.r.ReadByte()
			if err != nil {
				return err
			}
			if next == se {
				break
			}
			b = next
		}
		body = append(body, b)
		if len(body) > 1024 {
			return io.ErrShortBuffer
		}
	}
	if len(body) == 2 && body[0] == optTType && body[1] == ttypeSend {
		msg := append([]byte{iac, sb, optTType, ttypeIs}, c.w.Type...)
		return c.send(append(msg, iac, se))
	}
	return nil
}

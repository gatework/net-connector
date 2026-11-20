package telnet_test

import (
	"io"
	"net"
	"testing"
	"time"

	"github.com/gatework/net-connector/transport"
	"github.com/gatework/net-connector/transport/telnet"
)

func TestNegotiationAndData(t *testing.T) {
	t.Parallel()
	client, server := net.Pipe()
	defer server.Close()
	c := telnet.NewConn(client, transport.Window{Width: 200, Height: 50})
	defer c.Close()

	go func() {
		// WILL ECHO, DO NAWS, DO TTYPE, DO LINEMODE, then data with an
		// escaped 255 and a TTYPE SEND subnegotiation.
		_, _ = server.Write([]byte{255, 251, 1, 255, 253, 31, 255, 253, 24, 255, 253, 34})
		_, _ = server.Write([]byte("Username:\xff\xff"))
		_, _ = server.Write([]byte{255, 250, 24, 1, 255, 240})
	}()
	answers := make(chan []byte, 1)
	go func() {
		want := []byte{
			255, 253, 1, // DO ECHO
			255, 251, 31, 255, 250, 31, 0, 200, 0, 50, 255, 240, // WILL NAWS + size
			255, 251, 24, // WILL TTYPE
			255, 252, 34, // WONT LINEMODE
			255, 250, 24, 0, 'v', 't', '1', '0', '0', 255, 240, // TTYPE IS vt100
		}
		got := make([]byte, len(want))
		_ = server.SetReadDeadline(time.Now().Add(5 * time.Second))
		_, _ = io.ReadFull(server, got)
		answers <- got
		answers <- want
	}()
	buf := make([]byte, 64)
	var data []byte
	_ = client.SetReadDeadline(time.Now().Add(5 * time.Second))
	for len(data) < len("Username:\xff") {
		n, err := c.Read(buf)
		if err != nil {
			t.Fatal(err)
		}
		data = append(data, buf[:n]...)
	}
	if string(data) != "Username:\xff" {
		t.Errorf("data = %q", data)
	}
	// Drain the TTYPE subnegotiation so its answer is sent.
	go func() { _, _ = c.Read(buf) }()
	got, want := <-answers, <-answers
	if string(got) != string(want) {
		t.Errorf("negotiation = %v\nwant          %v", got, want)
	}
}

func TestWriteEscapesIAC(t *testing.T) {
	t.Parallel()
	client, server := net.Pipe()
	defer server.Close()
	c := telnet.NewConn(client, transport.Window{})
	defer c.Close()
	go func() { _, _ = c.Write([]byte{'a', 255, 'b'}) }()
	got := make([]byte, 4)
	_ = server.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := io.ReadFull(server, got); err != nil || string(got) != "a\xff\xffb" {
		t.Fatalf("%q %v", got, err)
	}
}

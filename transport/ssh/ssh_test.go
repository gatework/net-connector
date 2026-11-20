package ssh_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	gssh "github.com/gliderlabs/ssh"
	"go.uber.org/goleak"
	xssh "golang.org/x/crypto/ssh"

	"github.com/gatework/net-connector/transport"
	"github.com/gatework/net-connector/transport/ssh"
	"github.com/gatework/netops/failure"
	"github.com/gatework/netops/secret"
)

func TestMain(m *testing.M) { goleak.VerifyTestMain(m) }

// server is an in-process SSH device: password "s3cret", a PTY shell that
// prints a prompt and echoes lines back.
type server struct {
	addr    string
	logins  atomic.Int32
	forward atomic.Int32
}

func signer(t *testing.T) gssh.Signer {
	t.Helper()
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	s, err := xssh.NewSignerFromKey(key)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func start(t *testing.T, key gssh.Signer) *server {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	s := &server{addr: ln.Addr().String()}
	srv := &gssh.Server{
		HostSigners: []gssh.Signer{key},
		PasswordHandler: func(_ gssh.Context, pw string) bool {
			s.logins.Add(1)
			return pw == "s3cret"
		},
		LocalPortForwardingCallback: func(gssh.Context, string, uint32) bool { s.forward.Add(1); return true },
		ChannelHandlers: map[string]gssh.ChannelHandler{
			"session":      gssh.DefaultSessionHandler,
			"direct-tcpip": gssh.DirectTCPIPHandler,
		},
		Handler: func(sess gssh.Session) {
			pty, _, ok := sess.Pty()
			if !ok || pty.Window.Width < 80 {
				_, _ = io.WriteString(sess, "no pty\n")
				return
			}
			_, _ = io.WriteString(sess, "sw1#")
			buf := make([]byte, 256)
			for {
				n, err := sess.Read(buf)
				if err != nil {
					return
				}
				if strings.Contains(string(buf[:n]), "exit") {
					return
				}
				_, _ = sess.Write(buf[:n])
				_, _ = io.WriteString(sess, "sw1#")
			}
		},
	}
	go func() { _ = srv.Serve(ln) }()
	t.Cleanup(func() { _ = srv.Close() })
	return s
}

func target(addr string) transport.Target {
	host, port, _ := net.SplitHostPort(addr)
	var p int
	for _, c := range port {
		p = p*10 + int(c-'0')
	}
	return transport.Target{Host: host, Port: p}
}

var auth = transport.Auth{Username: "admin", Password: secret.New("s3cret")}

func dial(t *testing.T, o ssh.Options, addr string, a transport.Auth) (io.ReadWriteCloser, error) {
	t.Helper()
	d, err := ssh.New(o)
	if err != nil {
		t.Fatal(err)
	}
	return d.Dial(t.Context(), target(addr), a, transport.Window{Width: 511, Height: 24})
}

func readUntil(t *testing.T, r io.Reader, want string) {
	t.Helper()
	var got []byte
	buf := make([]byte, 64)
	deadline := time.Now().Add(5 * time.Second)
	for !strings.Contains(string(got), want) {
		if time.Now().After(deadline) {
			t.Fatalf("read %q, want %q", got, want)
		}
		n, err := r.Read(buf)
		if err != nil {
			t.Fatalf("read %q then %v", got, err)
		}
		got = append(got, buf[:n]...)
	}
}

func TestHostKeyPolicies(t *testing.T) {
	t.Parallel()
	key := signer(t)
	srv := start(t, key)
	kh := filepath.Join(t.TempDir(), "known_hosts")

	if _, err := dial(t, ssh.Options{KnownHosts: kh}, srv.addr, auth); failure.Primary(err) != failure.CodeHostKey {
		t.Fatalf("strict unknown: %v", err)
	}
	s, err := dial(t, ssh.Options{KnownHosts: kh, HostKeys: ssh.AcceptNew}, srv.addr, auth)
	if err != nil {
		t.Fatalf("accept-new: %v", err)
	}
	readUntil(t, s, "sw1#")
	if _, err := io.WriteString(s, "show clock\n"); err != nil {
		t.Fatal(err)
	}
	readUntil(t, s, "show clock")
	_ = s.Close()

	s, err = dial(t, ssh.Options{KnownHosts: kh}, srv.addr, auth)
	if err != nil {
		t.Fatalf("strict after recording: %v", err)
	}
	_ = s.Close()

	// The device is re-keyed on the same address.
	rekeyed := start(t, signer(t))
	body, _ := os.ReadFile(kh)
	_ = os.WriteFile(kh, []byte(strings.ReplaceAll(string(body), srv.addr[strings.LastIndex(srv.addr, ":")+1:], rekeyed.addr[strings.LastIndex(rekeyed.addr, ":")+1:])), 0o600)
	if _, err := dial(t, ssh.Options{KnownHosts: kh, HostKeys: ssh.AcceptNew}, rekeyed.addr, auth); failure.Primary(err) != failure.CodeHostKey || failure.Reason(err) != "changed_host_key" {
		t.Fatalf("accept-new changed: %v", err)
	}
	s, err = dial(t, ssh.Options{KnownHosts: kh, HostKeys: ssh.Replace}, rekeyed.addr, auth)
	if err != nil {
		t.Fatalf("replace: %v", err)
	}
	_ = s.Close()
	if s, err = dial(t, ssh.Options{KnownHosts: kh}, rekeyed.addr, auth); err != nil {
		t.Fatalf("strict after replace: %v", err)
	}
	_ = s.Close()
}

func TestReplaceNeedsExplicitFile(t *testing.T) {
	t.Parallel()
	if _, err := ssh.New(ssh.Options{HostKeys: ssh.Replace}); failure.Primary(err) != failure.CodeInvalid {
		t.Fatalf("err = %v", err)
	}
}

func TestWrongPasswordIsAuthAndNotRetried(t *testing.T) {
	t.Parallel()
	srv := start(t, signer(t))
	kh := filepath.Join(t.TempDir(), "known_hosts")
	d, err := ssh.New(ssh.Options{KnownHosts: kh, HostKeys: ssh.AcceptNew})
	if err != nil {
		t.Fatal(err)
	}
	r := transport.Retrying{Dialer: d, Retries: 3, Backoff: time.Millisecond}
	_, err = r.Dial(t.Context(), target(srv.addr), transport.Auth{Username: "admin", Password: secret.New("wrong")}, transport.Window{})
	if failure.Primary(err) != failure.CodeAuth {
		t.Fatalf("err = %v", err)
	}
	// One connection: password then keyboard-interactive, never a second dial.
	if n := srv.logins.Load(); n > 2 {
		t.Errorf("password tried %d times", n)
	}
}

func TestUnreachableIsRetried(t *testing.T) {
	t.Parallel()
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := ln.Addr().String()
	_ = ln.Close() // nothing listens: connection refused
	d, _ := ssh.New(ssh.Options{KnownHosts: filepath.Join(t.TempDir(), "kh"), Timeout: time.Second})
	var calls atomic.Int32
	r := transport.Retrying{Dialer: counting{d, &calls}, Retries: 2, Backoff: time.Millisecond}
	_, err := r.Dial(t.Context(), target(addr), auth, transport.Window{})
	if failure.Primary(err) != failure.CodeUnreachable || calls.Load() != 3 {
		t.Fatalf("err = %v after %d calls", err, calls.Load())
	}
}

type counting struct {
	transport.Dialer
	n *atomic.Int32
}

func (c counting) Dial(ctx context.Context, t transport.Target, a transport.Auth, w transport.Window) (io.ReadWriteCloser, error) {
	c.n.Add(1)
	return c.Dialer.Dial(ctx, t, a, w)
}

func TestJumpHost(t *testing.T) {
	t.Parallel()
	jump := start(t, signer(t))
	dev := start(t, signer(t))
	kh := filepath.Join(t.TempDir(), "known_hosts")
	s, err := dial(t, ssh.Options{KnownHosts: kh, HostKeys: ssh.AcceptNew, Jump: "ops@" + jump.addr}, dev.addr, auth)
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	readUntil(t, s, "sw1#")
	if jump.forward.Load() != 1 {
		t.Errorf("jump forwarded %d connections", jump.forward.Load())
	}
}

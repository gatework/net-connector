// Package ssh is the SSH transport, built on golang.org/x/crypto/ssh with
// skeema/knownhosts for host key verification. Jump hosts are chained in
// process; no ssh binary or PTY is involved.
package ssh

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"slices"
	"strings"
	"time"

	xssh "golang.org/x/crypto/ssh"

	"github.com/gatework/net-connector/transport"
	"github.com/gatework/netops/failure"
)

// Options configure the SSH transport.
type Options struct {
	// KnownHosts is the known_hosts file; empty means ~/.ssh/known_hosts.
	KnownHosts string
	// HostKeys decides what to do with unknown or changed host keys.
	HostKeys Policy
	// Jump is an optional jump host, "user@host:port". It authenticates
	// with the same Auth unless JumpAuth is set.
	Jump     string
	JumpAuth *transport.Auth
	// Legacy enables the insecure key exchanges, ciphers and host key
	// algorithms that old network devices still require. Enable it per
	// device group, not globally.
	Legacy bool
	// Timeout bounds TCP connect and SSH handshake; zero means 30s.
	Timeout time.Duration
	// KeepAlive sends keepalive requests at this interval; zero means 30s,
	// negative disables.
	KeepAlive time.Duration
}

// Dialer is the SSH transport. It is immutable and safe for concurrent use.
type Dialer struct {
	o     Options
	trust *trust
}

var _ transport.Dialer = (*Dialer)(nil)

// New validates the options. Policy Replace requires an explicit
// KnownHosts, so the user's own file is never rewritten implicitly.
func New(o Options) (*Dialer, error) {
	if o.HostKeys == "" {
		o.HostKeys = Strict
	}
	if !o.HostKeys.valid() {
		return nil, failure.New(failure.CodeInvalid, "ssh: host key policy")
	}
	explicit := o.KnownHosts != ""
	if !explicit {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, failure.Wrap(failure.CodeInvalid, "ssh: known_hosts", err)
		}
		o.KnownHosts = home + "/.ssh/known_hosts"
	}
	if o.HostKeys == Replace && !explicit {
		return nil, failure.New(failure.CodeInvalid, "ssh: replace needs an explicit known_hosts")
	}
	if o.Timeout <= 0 {
		o.Timeout = 30 * time.Second
	}
	if o.KeepAlive == 0 {
		o.KeepAlive = 30 * time.Second
	}
	return &Dialer{o: o, trust: &trust{path: o.KnownHosts, policy: o.HostKeys}}, nil
}

// Dial connects, authenticates, requests a PTY of size w and starts a
// shell.
func (d *Dialer) Dial(ctx context.Context, t transport.Target, a transport.Auth, w transport.Window) (io.ReadWriteCloser, error) {
	var closers []io.Closer
	fail := func(err error) (io.ReadWriteCloser, error) {
		for _, c := range slices.Backward(closers) {
			_ = c.Close()
		}
		return nil, err
	}
	dial := func(ctx context.Context, addr string) (net.Conn, error) {
		var nd net.Dialer
		return nd.DialContext(ctx, "tcp", addr)
	}
	if d.o.Jump != "" {
		jt, ju, err := parseJump(d.o.Jump)
		if err != nil {
			return nil, err
		}
		ja := a
		if d.o.JumpAuth != nil {
			ja = *d.o.JumpAuth
		}
		if ju != "" {
			ja.Username = ju
		}
		jc, err := d.client(ctx, jt.Address(22), ja, dial)
		if err != nil {
			return nil, err
		}
		closers = append(closers, jc)
		dial = func(ctx context.Context, addr string) (net.Conn, error) { return jc.DialContext(ctx, "tcp", addr) }
	}
	c, err := d.client(ctx, t.Address(22), a, dial)
	if err != nil {
		return fail(err)
	}
	closers = append(closers, c)
	sess, err := c.NewSession()
	if err != nil {
		return fail(failure.Wrap(failure.CodeClosed, "ssh: session", err))
	}
	closers = append(closers, sess)
	in, err := sess.StdinPipe()
	if err != nil {
		return fail(failure.Wrap(failure.CodeInternal, "ssh: stdin", err))
	}
	r, pw := io.Pipe()
	sess.Stdout, sess.Stderr = pw, pw
	term := w.Type
	if term == "" {
		term = "vt100"
	}
	modes := xssh.TerminalModes{xssh.ECHO: 1, xssh.TTY_OP_ISPEED: 38400, xssh.TTY_OP_OSPEED: 38400}
	if err := sess.RequestPty(term, max(w.Height, 24), max(w.Width, 80), modes); err != nil {
		return fail(failure.Wrap(failure.CodeProtocol, "ssh: pty", err))
	}
	if err := sess.Shell(); err != nil {
		return fail(failure.Wrap(failure.CodeProtocol, "ssh: shell", err))
	}
	s := &stream{in: in, out: r, pw: pw, closers: closers, done: make(chan struct{})}
	go s.wait(sess)
	if d.o.KeepAlive > 0 {
		go s.keepAlive(c, d.o.KeepAlive)
	}
	return s, nil
}

func (d *Dialer) client(ctx context.Context, addr string, a transport.Auth, dial func(context.Context, string) (net.Conn, error)) (*xssh.Client, error) {
	ctx, cancel := context.WithTimeout(ctx, d.o.Timeout)
	defer cancel()
	cfg, err := d.config(addr, a)
	if err != nil {
		return nil, err
	}
	conn, err := dial(ctx, addr)
	if err != nil {
		return nil, transport.Classify("ssh: connect", err)
	}
	// The handshake has no context; bound it with the connection deadline
	// and abort it on cancellation.
	if dl, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(dl)
	}
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	cc, chans, reqs, err := xssh.NewClientConn(conn, addr, cfg)
	if err != nil {
		_ = conn.Close()
		return nil, d.classify(ctx, err)
	}
	_ = conn.SetDeadline(time.Time{})
	return xssh.NewClient(cc, chans, reqs), nil
}

func (d *Dialer) config(addr string, a transport.Auth) (*xssh.ClientConfig, error) {
	methods, err := authMethods(a)
	if err != nil {
		return nil, err
	}
	cfg := &xssh.ClientConfig{
		User:              a.Username,
		Auth:              methods,
		HostKeyCallback:   d.trust.callback,
		HostKeyAlgorithms: d.trust.algorithms(addr),
		Timeout:           d.o.Timeout,
	}
	if d.o.Legacy {
		sup, ins := xssh.SupportedAlgorithms(), xssh.InsecureAlgorithms()
		cfg.KeyExchanges = slices.Concat(sup.KeyExchanges, ins.KeyExchanges)
		cfg.Ciphers = slices.Concat(sup.Ciphers, ins.Ciphers)
		cfg.MACs = slices.Concat(sup.MACs, ins.MACs)
		if len(cfg.HostKeyAlgorithms) == 0 {
			cfg.HostKeyAlgorithms = slices.Concat(sup.HostKeys, ins.HostKeys)
		}
	}
	return cfg, nil
}

func authMethods(a transport.Auth) ([]xssh.AuthMethod, error) {
	var methods []xssh.AuthMethod
	if a.IdentityFile != "" {
		key, err := os.ReadFile(a.IdentityFile)
		if err != nil {
			return nil, failure.Wrap(failure.CodeNoCreds, "ssh: identity", err)
		}
		var signer xssh.Signer
		if a.Passphrase.Empty() {
			signer, err = xssh.ParsePrivateKey(key)
		} else {
			signer, err = xssh.ParsePrivateKeyWithPassphrase(key, []byte(a.Passphrase.Reveal()))
		}
		if err != nil {
			return nil, failure.Wrap(failure.CodeNoCreds, "ssh: identity", err)
		}
		methods = append(methods, xssh.PublicKeys(signer))
	}
	if !a.Password.Empty() {
		pw := a.Password.Reveal()
		methods = append(methods, xssh.Password(pw),
			// Many devices authenticate passwords through keyboard-interactive.
			// Answer only hidden prompts, and only once per question set.
			xssh.KeyboardInteractive(func(_, _ string, questions []string, echos []bool) ([]string, error) {
				answers := make([]string, len(questions))
				for i := range questions {
					if echos[i] {
						return nil, errors.New("ssh: unexpected visible prompt")
					}
					answers[i] = pw
				}
				return answers, nil
			}))
	}
	if len(methods) == 0 {
		return nil, failure.New(failure.CodeNoCreds, "ssh: no credentials")
	}
	return methods, nil
}

func (d *Dialer) classify(ctx context.Context, err error) error {
	var hk *hostKeyError
	switch {
	case errors.As(err, &hk):
		return failure.Wrap(failure.CodeHostKey, "ssh: host key", err).Because(hk.reason)
	case strings.Contains(err.Error(), "unable to authenticate"):
		return failure.Wrap(failure.CodeAuth, "ssh: authenticate", err)
	case ctx.Err() == context.DeadlineExceeded:
		return failure.Wrap(failure.CodeTimeout, "ssh: handshake", err)
	case ctx.Err() == context.Canceled:
		return failure.Wrap(failure.CodeCancelled, "ssh: handshake", err)
	case strings.Contains(err.Error(), "no common algorithm"):
		return failure.Wrap(failure.CodeProtocol, "ssh: handshake", err).Because("no_common_algorithm")
	}
	return transport.Classify("ssh: handshake", err)
}

func parseJump(s string) (transport.Target, string, error) {
	user, hostport, ok := strings.Cut(s, "@")
	if !ok {
		user, hostport = "", s
	}
	host, port := hostport, 0
	if h, p, err := net.SplitHostPort(hostport); err == nil {
		host = h
		if _, err := fmt.Sscanf(p, "%d", &port); err != nil {
			return transport.Target{}, "", failure.New(failure.CodeInvalid, "ssh: jump host")
		}
	}
	if host == "" {
		return transport.Target{}, "", failure.New(failure.CodeInvalid, "ssh: jump host")
	}
	return transport.Target{Host: host, Port: port}, user, nil
}

// stream joins the session's stdin and output into one ReadWriteCloser.
// Close interrupts a blocked Read.
type stream struct {
	in      io.WriteCloser
	out     *io.PipeReader
	pw      *io.PipeWriter
	closers []io.Closer
	done    chan struct{}
}

func (s *stream) Read(p []byte) (int, error)  { return s.out.Read(p) }
func (s *stream) Write(p []byte) (int, error) { return s.in.Write(p) }

func (s *stream) Close() error {
	select {
	case <-s.done:
	default:
		close(s.done)
	}
	var errs []error
	for _, c := range slices.Backward(s.closers) {
		if err := c.Close(); err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, net.ErrClosed) {
			errs = append(errs, err)
		}
	}
	_ = s.out.Close()
	return errors.Join(errs...)
}

// wait ends the output when the shell exits.
func (s *stream) wait(sess *xssh.Session) {
	_ = sess.Wait()
	_ = s.pw.Close()
}

func (s *stream) keepAlive(c *xssh.Client, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-s.done:
			return
		case <-t.C:
			if _, _, err := c.SendRequest("keepalive@openssh.com", true, nil); err != nil {
				_ = s.pw.CloseWithError(err)
				return
			}
		}
	}
}

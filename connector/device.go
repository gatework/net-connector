package connector

import (
	"context"
	"errors"
	"io"
	"maps"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	expect "github.com/gatework/go-expect"
	"github.com/gatework/net-connector/internal/nilcheck"
	"github.com/gatework/net-connector/internal/terminal"
	"github.com/gatework/net-connector/internal/textcodec"
)

// Device owns one conversation. Close is terminal and cancels admitted work.
// A failed operation requires explicit Connect before another command; no replay.
// Do not copy Device. Callbacks and borrowed writers must cooperate with cancellation.
type Device struct {
	lifeMu     sync.Mutex
	closed     bool
	cancel     context.CancelFunc
	retired    atomic.Bool
	terminal   Terminal
	driver     Driver
	preparer   CommandPreparer
	observer   CommandObserver
	inspector  LoginInspector
	config     ConnectionConfig
	factory    TransportFactory
	lease      atomic.Bool
	connected  atomic.Bool
	privileged atomic.Bool
	labels     atomic.Pointer[map[string]string]
	prompt     atomic.Value
	session    *expect.Session
	transport  io.ReadWriteCloser
	owner      *closeOwner
	log        *logWriter
	operation  *Operation // Accessed only by the holder of lease.
}

// New constructs an unconnected Device for driver d. It never opens a
// connection; register Close, then call Connect explicitly.
func New(d Driver, cfg ConnectionConfig, opts ...Option) (*Device, error) {
	if nilcheck.IsNil(d) {
		return nil, ErrInvalid
	}
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	p, e := d.Terminal().normalized()
	if e != nil {
		return nil, e
	}
	if cfg.LineEnding == "" {
		cfg.LineEnding = "\n"
	}
	if cfg.Protocol == "" {
		cfg.Protocol = ProtocolSSH
	}
	if cfg.HostKeyPolicy == "" {
		cfg.HostKeyPolicy = HostKeyStrict
	}
	if cfg.LoginTimeout == 0 {
		cfg.LoginTimeout = 10 * time.Second
	}
	if cfg.CommandTimeout == 0 {
		cfg.CommandTimeout = p.CommandTimeout
	}
	if cfg.WriteTimeout == 0 {
		cfg.WriteTimeout = 10 * time.Second
	}
	if cfg.MaxOutputBytes == 0 {
		cfg.MaxOutputBytes = 32 << 20
	}
	if e = validateInteractions(cfg.Challenges); e != nil {
		return nil, e
	}
	cfg.Challenges = slices.Clone(cfg.Challenges)
	cfg.LegacyCryptoArguments = slices.Clone(cfg.LegacyCryptoArguments)
	o := options{factory: openProcess}
	for _, opt := range opts {
		if opt == nil {
			return nil, ErrInvalid
		}
		if e = opt(&o); e != nil {
			return nil, e
		}
	}
	device := &Device{terminal: p, driver: d, config: cfg, factory: o.factory}
	device.preparer, device.observer, device.inspector = driverHooks(d)
	device.prompt.Store(promptState{err: ErrIncomplete})
	device.log = &logWriter{target: cfg.Logger, level: cfg.LogLevel, host: cfg.Host, encoding: "auto", paused: true}
	return device, nil
}

// PlatformName returns the terminal declaration name.
func (d *Device) PlatformName() string { return d.terminal.Name }

// ConfigCommands returns a copy of the exact running-configuration sequence.
func (d *Device) ConfigCommands() []string { return slices.Clone(d.terminal.ConfigCommands) }

// SaveCommands returns a copy of the platform's persistence sequence.
func (d *Device) SaveCommands() []string { return slices.Clone(d.terminal.SaveCommands) }

// Host returns the configured device host.
func (d *Device) Host() string { return d.config.Host }

// Connected reports whether authentication completed on the current session.
func (d *Device) Connected() bool { return d.connected.Load() }

type promptState struct {
	raw, text string
	err       error
}

// RawPrompt returns the last accepted prompt without decoding or redaction.
func (d *Device) RawPrompt() string {
	s, _ := d.prompt.Load().(promptState)
	return s.raw
}

// Prompt returns the last prompt as verified text or its conversion error.
func (d *Device) Prompt() (string, error) {
	s, _ := d.prompt.Load().(promptState)
	return s.text, s.err
}

// Connect explicitly establishes a session and retires it on failure.
func (d *Device) Connect(ctx context.Context) (err error) {
	if err = d.acquire(); err != nil {
		return err
	}
	defer d.release()
	ctx, cancel := d.operationContext(ctx)
	defer cancel()
	returned := false
	defer func() {
		if !returned {
			_ = d.closeResources()
		} else if err != nil {
			err = joinCleanup(err, d.closeResources())
		}
	}()
	d.retired.Store(false)
	err = d.connect(ctx)
	if err == nil {
		err = ctx.Err()
	}
	returned = true
	return
}

// Close rejects new work and interrupts admitted I/O without waiting for callbacks.
// A later Close can retry cleanup that previously failed.
func (d *Device) Close() error {
	d.lifeMu.Lock()
	d.closed = true
	d.connected.Store(false)
	if d.cancel != nil {
		d.cancel()
	}
	session := d.session
	d.lifeMu.Unlock()
	var err error
	if session != nil {
		err = session.Close()
	}
	if d.lease.CompareAndSwap(false, true) {
		defer d.release()
		err = errors.Join(err, d.closeResources())
	}
	if err != nil {
		return newError("cleanup_failed", "cleanup", Command{}, err)
	}
	return nil
}

// LoginLabel returns a fact the platform read from the login banner, such as
// "ha_state", while the device is connected.
func (d *Device) LoginLabel(name string) string {
	labels := d.labels.Load()
	if labels == nil || !d.connected.Load() {
		return ""
	}
	return (*labels)[name]
}

func (d *Device) setPrompt(response Response) {
	raw := strings.Trim(response.RawPrompt(), " \t\r\n\x00")
	// A privilege acknowledgement may be part of the match. Only its final
	// wire line identifies the next command boundary.
	if i := strings.LastIndexAny(raw, "\r\n"); i >= 0 {
		raw = strings.Trim(raw[i+1:], " \t\x00")
	}
	text, _, err := textcodec.Decode(raw, "auto")
	if err == nil {
		text, err = terminal.RenderString(text, true)
	}
	d.prompt.Store(promptState{raw: raw, text: text, err: err})
}
func (d *Device) acquire() error {
	d.lifeMu.Lock()
	defer d.lifeMu.Unlock()
	if d.closed {
		return ErrClosed
	}
	if !d.lease.CompareAndSwap(false, true) {
		return ErrBusy
	}
	return nil
}

var errConnectionRefused = errors.New("connector: connection refused")
var errNoRoute = errors.New("connector: no route to host")
var errConnectTimeout = errors.New("connector: connection timed out")

// unreachable reports connection failures that happen before the device shows
// any login prompt, so no credential or command has been written.
func unreachable(err error) bool {
	return errors.Is(err, errConnectionRefused) || errors.Is(err, errNoRoute) || errors.Is(err, errConnectTimeout)
}

var errCleanup = errors.New("connector: cleanup failed")
var errHostKeyChanged = errors.New("connector: host key changed")
var errRSATooSmall = errors.New("connector: RSA modulus too small")
var errUnsupportedCipher = errors.New("connector: unsupported cipher")

func (d *Device) release() { d.lease.Store(false) }

// connectRetryDelay is the linear backoff unit between connection attempts.
var connectRetryDelay = 2 * time.Second

// operationContext links all callbacks and I/O in an admitted operation to Close.
func (d *Device) operationContext(parent context.Context) (context.Context, func()) {
	ctx, cancel := context.WithCancel(parent)
	d.lifeMu.Lock()
	if d.closed {
		cancel()
	} else {
		d.cancel = cancel
	}
	d.lifeMu.Unlock()
	return ctx, func() { cancel(); d.lifeMu.Lock(); d.cancel = nil; d.lifeMu.Unlock() }
}

// connect connects once, then retries only failures that happened before any
// login prompt (refused, no route, timed out): nothing was written, so a retry
// cannot replay a credential or a command. Authentication failures and every
// failure after login begins are never retried.
func (d *Device) connect(parent context.Context) error {
	for attempt := 0; ; attempt++ {
		err := d.connectWithRecovery(parent)
		if err == nil || !unreachable(err) || attempt >= d.config.ConnectRetries || d.connected.Load() {
			return err
		}
		if e := d.sessionEvent(parent, "connect_retry", LogWarn, Command{}, ""); e != nil {
			return joinFailures(err, e)
		}
		timer := time.NewTimer(time.Duration(attempt+1) * connectRetryDelay)
		select {
		case <-parent.Done():
			timer.Stop()
			return parent.Err()
		case <-timer.C:
		}
		// Only this call's own pre-login failures retired the session; nothing
		// was written, so the next attempt is still the same initial connect.
		d.retired.Store(false)
	}
}
func (d *Device) connectWithRecovery(parent context.Context) error {
	if err := parent.Err(); err != nil {
		return err
	}
	if d.retired.Load() {
		return ErrNotConnected
	}
	if d.operation != nil && d.operation.borrowed {
		if !d.connected.Load() {
			return ErrNotConnected
		}
		return nil
	}
	if d.connected.Load() {
		return parent.Err()
	}
	ctx, cancel := context.WithTimeout(parent, d.config.LoginTimeout)
	defer cancel()
	cfg := d.config
	// Legacy options are selected only after a recognized failure.
	cfg.LegacyCryptoArguments = nil
	cfg.replaceHostKey = false
	err := d.connectOnce(ctx, cfg)
	if err == nil || cfg.Protocol != ProtocolSSH || errors.Is(err, errCleanup) || d.transport != nil || ctx.Err() != nil {
		return err
	}
	switch {
	case d.config.AllowTelnetFallback && errors.Is(err, errConnectionRefused):
		cfg.Protocol = ProtocolTelnet
		cfg.Port = 0
	case d.config.HostKeyPolicy == HostKeyReplace && errors.Is(err, errHostKeyChanged):
		cfg.replaceHostKey = true
	case d.config.AllowLegacyCrypto && errors.Is(err, errRSATooSmall) && len(d.terminal.LegacyCryptoArguments) > 0:
		cfg.LegacyCryptoArguments = slices.Clone(d.terminal.LegacyCryptoArguments)
	case d.config.AllowLegacyCrypto && errors.Is(err, errUnsupportedCipher):
		cfg.LegacyCryptoArguments = []string{"-c", "des"}
	default:
		return err
	}
	return d.connectOnce(ctx, cfg)
}
func (d *Device) connectOnce(ctx context.Context, cfg ConnectionConfig) (err error) {
	if err = ctx.Err(); err != nil {
		return
	}
	if d.connected.Load() {
		return nil
	}
	if d.transport != nil {
		if err = d.closeResources(); err != nil {
			return
		}
	}
	if e := d.log.scope(d.baseSecrets(), true); e != nil {
		return newError("log_error", "logging", Command{}, e)
	}
	if e := d.sessionEvent(ctx, "connect", LogInfo, Command{}, ""); e != nil {
		return e
	}
	defer func() {
		if err != nil {
			err = joinFailures(err, d.sessionEvent(ctx, "connect_failed", LogError, Command{}, "failed"))
		}
	}()
	t, session, e := d.openSession(ctx, cfg)
	if e != nil {
		return e
	}
	d.lifeMu.Lock()
	if d.closed {
		d.lifeMu.Unlock()
		return errors.Join(ErrClosed, session.Close())
	}
	d.session = session
	d.lifeMu.Unlock()
	defer func() {
		if err != nil {
			if cleanup := d.closeResources(); cleanup != nil {
				err = joinFailures(err, newError("cleanup_failed", "cleanup", Command{}, errors.Join(errCleanup, cleanup)))
			}
		}
	}()
	if e = d.log.scope(d.baseSecrets(), true); e != nil {
		return newError("log_error", "logging", Command{}, e)
	}
	authctx, cancel := context.WithTimeout(ctx, d.config.LoginTimeout)
	defer cancel()
	interactions := d.loginInteractions(d.config.Password)
	response, e := d.readResponse(authctx, Command{}, d.terminal.LoginPrompt, interactions, true, false)
	if e != nil {
		return e
	}
	d.lifeMu.Lock()
	if d.closed || ctx.Err() != nil {
		d.lifeMu.Unlock()
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return ErrClosed
	}
	d.setPrompt(response.Response())
	d.connected.Store(true)
	d.lifeMu.Unlock()
	d.retired.Store(false)
	d.privileged.Store(d.terminal.PrivilegedPrompt != nil && d.terminal.PrivilegedPrompt.MatchString(response.Response().RawPrompt()))
	return d.finishLogin(ctx, t, response)
}

// openSession transfers every partial factory result into owned cleanup before
// constructing the matching session.
func (d *Device) openSession(ctx context.Context, cfg ConnectionConfig) (io.ReadWriteCloser, *expect.Session, error) {
	cfg.Challenges = slices.Clone(cfg.Challenges)
	cfg.LegacyCryptoArguments = slices.Clone(cfg.LegacyCryptoArguments)
	t, e := d.factory(ctx, cfg)
	// A partial factory return still transfers cleanup responsibility.
	if !nilcheck.IsNil(t) {
		d.transport = t
		d.owner = &closeOwner{ReadWriteCloser: t}
	}
	if e != nil {
		return nil, nil, joinCleanup(newError("connection_failed", "connect", Command{}, e), d.closeResources())
	}
	if nilcheck.IsNil(t) {
		return nil, nil, ErrConnection
	}
	var owned io.ReadWriteCloser = d.owner
	if conn, ok := t.(syscall.Conn); ok {
		owned = &osCloseOwner{closeOwner: d.owner, Conn: conn}
	}
	opts := []expect.SessionOption{expect.WithBufferLimit(int(d.config.MaxOutputBytes)), expect.WithDefaultTimeout(0), expect.WithWriteTimeout(0), expect.WithOutput(d.log)}
	if _, ok := t.(syscall.Conn); ok {
		opts = append(opts, expect.WithOSPolling())
	}
	session, e := expect.NewSession(owned, opts...)
	if e != nil {
		return nil, nil, joinCleanup(e, d.closeResources())
	}
	return t, session, nil
}

// finishLogin runs post-authentication checks after publishing the accepted prompt.
func (d *Device) finishLogin(ctx context.Context, t io.ReadWriteCloser, response StepResult) error {
	if d.inspector != nil {
		// Freeze verified text before publishing the login response. A callback
		// may inspect conversion errors or choose to consume only the raw banner.
		_, _ = response.response.data.convert()
		state, err := d.inspector.AfterLogin(ctx, response)
		if err != nil {
			return newError("after_login_failed", "login", Command{}, err)
		}
		labels := maps.Clone(state.Labels)
		d.labels.Store(&labels)
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if c, ok := t.(LoginCommitter); ok {
		if e := c.Authenticated(ctx); e != nil {
			return newError("host_key_commit_failed", "login", Command{}, e)
		}
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	return d.sessionEvent(ctx, "login_complete", LogInfo, Command{}, "ok")
}

func (d *Device) baseSecrets() []string {
	var s []string
	for _, v := range []string{d.config.Username, d.config.Password, d.config.EnablePassword, d.config.KeyPassphrase} {
		if v != "" {
			s = append(s, v)
		}
	}
	return s
}

func (d *Device) loginInteractions(secret string) []Interaction {
	hostkey := Interaction{Pattern: hostKeyQuestion, Limit: 1, Respond: func(context.Context, string) (string, error) {
		if d.config.HostKeyPolicy == HostKeyStrict {
			return "", ErrAuthentication
		}
		return "yes\n", nil
	}}
	user := Interaction{Pattern: d.terminal.UsernamePrompt, Limit: 1, Sensitive: true, Respond: func(context.Context, string) (string, error) {
		if d.config.Username == "" {
			return "", ErrAuthentication
		}
		return d.config.Username + d.config.LineEnding, nil
	}}
	pass := Interaction{Pattern: d.terminal.PasswordPrompt, Limit: 1, Sensitive: true, Respond: func(context.Context, string) (string, error) {
		if secret == "" {
			return "", ErrAuthentication
		}
		return secret + d.config.LineEnding, nil
	}}
	replies := []Interaction{hostkey}
	replies = append(replies, d.terminal.LoginInteractions...)
	replies = append(replies, d.config.Challenges...)
	if d.config.KeyPassphrase != "" {
		replies = append(replies, Interaction{Pattern: keyPassphraseQuestion, Reply: d.config.KeyPassphrase + d.config.LineEnding, Limit: 1, Sensitive: true})
	}
	return append(replies, user, pass)
}

func (d *Device) closeResources() error {
	if o := d.operation; o != nil && (o.borrowed || o.retired.Load()) {
		return o.retire()
	}
	return d.closeOwnedResources()
}

func (d *Device) retireFailure(err error) error {
	cleanupErr := d.closeResources()
	if d.operation != nil && d.operation.borrowed {
		return err
	}
	return joinCleanup(err, cleanupErr)
}
func (d *Device) closeOwnedResources() error {
	d.retired.Store(true)
	d.connected.Store(false)
	d.privileged.Store(false)
	d.labels.Store(nil)
	d.prompt.Store(promptState{err: ErrIncomplete})
	var failure error
	d.lifeMu.Lock()
	session := d.session
	d.lifeMu.Unlock()
	if session != nil {
		failure = session.Close()
		d.lifeMu.Lock()
		d.session = nil
		d.lifeMu.Unlock()
	}
	if d.transport != nil {
		var e error
		if d.owner != nil {
			if !d.owner.complete() {
				e = d.owner.Close()
			}
			if d.owner.complete() {
				d.transport = nil
				d.owner = nil
			}
		} else {
			e = d.transport.Close()
			if e == nil {
				d.transport = nil
			}
		}
		failure = errors.Join(failure, e)
	}
	failure = errors.Join(failure, d.log.finish())
	return failure
}

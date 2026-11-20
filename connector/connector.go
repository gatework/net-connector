package connector

import (
	"context"
	"errors"
	"log/slog"
	"strings"
	"time"

	"github.com/gatework/net-connector/driver"
	"github.com/gatework/net-connector/terminal"
	"github.com/gatework/net-connector/transport"
	"github.com/gatework/netops/capture"
	"github.com/gatework/netops/change"
	"github.com/gatework/netops/credential"
	"github.com/gatework/netops/device"
	"github.com/gatework/netops/failure"
	"github.com/gatework/netops/ops"
)

// Options configure a Dialer.
type Options struct {
	// Registry resolves device platforms; required.
	Registry *driver.Registry
	// Credentials supplies device credentials; required.
	Credentials credential.Provider
	// Transport opens streams, normally an SSH dialer wrapped in
	// transport.Retrying; required.
	Transport transport.Dialer
	// Port overrides the transport's default port.
	Port int
	// Timeout bounds one command; zero means 2 minutes.
	Timeout time.Duration
	// MaxOutput bounds one response; zero means 64 MiB.
	MaxOutput int
	// Preparation adds commands sent after login, per platform key, for
	// tool-specific terminal settings.
	Preparation map[string][]string
	Logger      *slog.Logger
	Now         func() time.Time
}

// Dialer opens sessions. It is immutable and safe for concurrent use.
type Dialer struct{ o Options }

// NewDialer validates the options.
func NewDialer(o Options) (*Dialer, error) {
	if o.Registry == nil || o.Credentials == nil || o.Transport == nil {
		return nil, failure.New(failure.CodeInvalid, "connector: registry, credentials and transport are required")
	}
	if o.Logger == nil {
		o.Logger = slog.New(slog.DiscardHandler)
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	return &Dialer{o: o}, nil
}

// CanConnect reports whether credentials exist for dev.
func (d *Dialer) CanConnect(ctx context.Context, dev device.Device) bool {
	_, err := d.o.Credentials.Lookup(ctx, dev)
	return err == nil
}

// Dial opens and logs in a session to dev. The caller must Close it.
func (d *Dialer) Dial(ctx context.Context, dev device.Device) (*Session, error) {
	drv, err := d.o.Registry.Lookup(dev.Platform)
	if err != nil {
		return nil, failure.Wrap(failure.CodeUnsupported, "connector: platform", err)
	}
	cr, err := d.o.Credentials.Lookup(ctx, dev)
	if err != nil {
		if _, ok := errors.AsType[*failure.Error](err); ok {
			return nil, err
		}
		return nil, failure.Wrap(failure.CodeNoCreds, "connector: credentials", err)
	}
	g := drv.Grammar()
	g.Preparation = append(g.Preparation, d.o.Preparation[dev.Platform]...)
	stream, err := d.o.Transport.Dial(ctx,
		transport.Target{Host: dev.Mgmt.String(), Port: d.o.Port},
		transport.Auth{Username: cr.Username, Password: cr.Password, IdentityFile: cr.IdentityFile, Passphrase: cr.KeyPassphrase},
		transport.Window{Width: g.LineWidth(), Height: 24})
	if err != nil {
		return nil, err
	}
	t, err := terminal.New(stream, g,
		terminal.Credentials{Username: cr.Username, Password: cr.Password, Enable: cr.EnablePassword},
		terminal.Options{Timeout: d.o.Timeout, MaxOutput: d.o.MaxOutput, Logger: d.o.Logger, Now: d.o.Now})
	if err != nil {
		return nil, errors.Join(err, stream.Close())
	}
	s := &Session{dev: dev.Clone(), drv: drv, t: t, now: d.o.Now, state: driver.LoginState{Writable: true}}
	if err := t.Login(ctx); err != nil {
		return nil, errors.Join(err, closeError(t.Close()))
	}
	if li, ok := driver.As[driver.LoginInspector](drv); ok {
		if s.state, err = li.AfterLogin(t.Banner(), t.Prompt()); err != nil {
			return nil, errors.Join(failure.Wrap(failure.CodeProtocol, "connector: login state", err), closeError(t.Close()))
		}
	}
	d.o.Logger.DebugContext(ctx, "connector: logged in", "device", dev.Label(), "platform", dev.Platform, "mode", t.Mode().String())
	return s, nil
}

// Open runs fn with a logged-in session to dev and closes it. It reports
// the operation error and the close error separately, so a caller can tell
// a failed write from a failed logout.
func (d *Dialer) Open(ctx context.Context, dev device.Device, fn func(context.Context, *Session) error) (opErr, closeErr error) {
	s, err := d.Dial(ctx, dev)
	if err != nil {
		return err, nil
	}
	defer func() { closeErr = s.Close() }()
	return fn(ctx, s), nil
}

// Port adapts the dialer to the netops ops.Dialer port.
func (d *Dialer) Port() ops.Dialer { return port{d} }

type port struct{ d *Dialer }

func (p port) Open(ctx context.Context, dev device.Device, fn func(context.Context, ops.Session) error) (error, error) {
	return p.d.Open(ctx, dev, func(ctx context.Context, s *Session) error { return fn(ctx, s) })
}

func (p port) CanConnect(ctx context.Context, dev device.Device) bool {
	return p.d.CanConnect(ctx, dev)
}

// Session is one logged-in device session. It is not safe for concurrent
// use; a concurrent call fails with CodeBusy.
type Session struct {
	dev   device.Device
	drv   driver.Driver
	t     *terminal.Session
	state driver.LoginState
	now   func() time.Time
}

var _ ops.Session = (*Session)(nil)

// Device returns the device.
func (s *Session) Device() device.Device { return s.dev.Clone() }

// Driver returns the platform driver.
func (s *Session) Driver() driver.Driver { return s.drv }

// State returns what the platform learned at login, such as an HA role.
func (s *Session) State() driver.LoginState { return s.state }

// Prompt returns the current prompt.
func (s *Session) Prompt() string { return s.t.Prompt() }

// Host returns the hostname learned from the prompt.
func (s *Session) Host() string { return s.t.Host() }

// Close logs out and closes the stream.
func (s *Session) Close() error { return closeError(s.t.Close()) }

// Run sends one command and returns the answer.
func (s *Session) Run(ctx context.Context, cmd terminal.Command) (terminal.Response, error) {
	return s.t.Run(ctx, cmd)
}

// Show runs a read command and returns its body. A rejected command is an
// error coded CodeRejected.
func (s *Session) Show(ctx context.Context, command string) (string, error) {
	r, err := s.t.Run(ctx, terminal.Command{Text: command})
	if err != nil {
		return "", err
	}
	if !r.OK() {
		return "", rejected("connector: show", r)
	}
	return r.Text(), nil
}

// Collect runs read commands into a capture. A rejected command is a
// failed output, not an error; a session failure stops collection and
// returns the partial capture with the error.
func (s *Session) Collect(ctx context.Context, commands []string) (capture.Capture, error) {
	c := capture.Capture{Host: s.dev.Mgmt, Prompt: s.t.Prompt(), Outputs: make([]capture.Output, 0, len(commands))}
	for _, cmd := range commands {
		start := s.now()
		r, err := s.t.Run(ctx, terminal.Command{Text: cmd})
		o := capture.Output{Command: cmd, Raw: r.Raw, Prompt: r.Prompt, RecordedAt: s.now().UTC(), Duration: s.now().Sub(start)}
		if err != nil {
			o.Failure = failure.Primary(err)
			c.Outputs = append(c.Outputs, o)
			return c, err
		}
		if !r.OK() {
			o.Failure = failure.CodeRejected
		}
		c.Outputs = append(c.Outputs, o)
		if r.Prompt != "" {
			c.Prompt = r.Prompt
		}
	}
	return c, nil
}

// Write sends one configuration command. A rejection is an error coded
// CodeRejected with the matched reason. HA members that must not be
// changed refuse writes before sending.
func (s *Session) Write(ctx context.Context, cmd change.Command) error {
	if !s.state.Writable {
		return failure.New(failure.CodeUnsupported, "connector: write").Because("ha_" + s.state.Role)
	}
	r, err := s.t.Run(ctx, terminal.Command{Text: cmd.Text, Sensitive: cmd.Sensitive})
	if err != nil {
		return err
	}
	if !r.OK() {
		return rejected("connector: write", r)
	}
	return nil
}

// Config reads and cleans the running configuration.
func (s *Session) Config(ctx context.Context) (string, error) {
	cr, ok := driver.As[driver.ConfigReader](s.drv)
	if !ok {
		return "", failure.New(failure.CodeUnsupported, "connector: config")
	}
	steps := cr.ConfigSteps()
	rs := make([]terminal.Response, 0, len(steps))
	for _, step := range steps {
		r, err := s.t.Run(ctx, step)
		if err == nil && !r.OK() {
			err = rejected("connector: config", r)
		}
		if err != nil {
			if s.t.Mode().Configuring() {
				// Never leave a read inside configuration mode.
				err = errors.Join(err, s.t.Enter(ctx, terminal.ModePrivileged))
			}
			return "", err
		}
		rs = append(rs, r)
	}
	text, err := cr.CleanConfig(rs)
	if err != nil {
		return "", failure.Wrap(failure.CodeIncomplete, "connector: config", err)
	}
	return text, nil
}

// Save persists the running configuration and requires the platform's
// affirmative evidence.
func (s *Session) Save(ctx context.Context) error {
	sv, ok := driver.As[driver.Saver](s.drv)
	if !ok {
		return failure.New(failure.CodeUnsupported, "connector: save")
	}
	_, err := s.t.Execute(ctx, sv.SaveProcedure())
	return err
}

// Commit loads body into the candidate configuration and commits it.
func (s *Session) Commit(ctx context.Context, body []string, o driver.CommitOptions) (terminal.Receipt, error) {
	cm, ok := driver.As[driver.Committer](s.drv)
	if !ok {
		return terminal.Receipt{}, failure.New(failure.CodeUnsupported, "connector: commit")
	}
	if !s.state.Writable {
		return terminal.Receipt{}, failure.New(failure.CodeUnsupported, "connector: commit").Because("ha_" + s.state.Role)
	}
	p, err := cm.CommitProcedure(body, o)
	if err != nil {
		return terminal.Receipt{}, failure.Wrap(failure.CodeInvalid, "connector: commit", err)
	}
	rec, err := s.t.Execute(ctx, p)
	if err != nil && s.t.Mode().Configuring() {
		// Leave the candidate so the session is usable; the device
		// discards an exclusive candidate on exit.
		err = errors.Join(err, s.t.Enter(ctx, terminal.ModePrivileged))
	}
	return rec, err
}

// Export uploads the configuration from the device.
func (s *Session) Export(ctx context.Context, e driver.Export) (terminal.Receipt, error) {
	ex, ok := driver.As[driver.Exporter](s.drv)
	if !ok {
		return terminal.Receipt{}, failure.New(failure.CodeUnsupported, "connector: export")
	}
	p, err := ex.ExportProcedure(e)
	if err != nil {
		return terminal.Receipt{}, failure.Wrap(failure.CodeInvalid, "connector: export", err)
	}
	return s.t.Execute(ctx, p)
}

// CanCheckpoint reports whether the platform declares checkpoints.
func (s *Session) CanCheckpoint() bool {
	_, ok := driver.As[driver.Checkpointer](s.drv)
	return ok
}

// Checkpoint records the running configuration under name.
func (s *Session) Checkpoint(ctx context.Context, name string) error {
	return s.checkpoint(ctx, name, driver.Checkpointer.CheckpointProcedure)
}

// Rollback restores the checkpoint name.
func (s *Session) Rollback(ctx context.Context, name string) error {
	return s.checkpoint(ctx, name, driver.Checkpointer.RollbackProcedure)
}

func (s *Session) checkpoint(ctx context.Context, name string, build func(driver.Checkpointer, string) (terminal.Procedure, error)) error {
	cp, ok := driver.As[driver.Checkpointer](s.drv)
	if !ok {
		return failure.New(failure.CodeUnsupported, "connector: checkpoint")
	}
	p, err := build(cp, name)
	if err != nil {
		return failure.Wrap(failure.CodeInvalid, "connector: checkpoint", err)
	}
	_, err = s.t.Execute(ctx, p)
	return err
}

// ReadOnly reports whether the platform declares command read-only. A
// platform without a ReadOnly declaration treats every command as a
// potential write.
func ReadOnly(d driver.Driver, command string) bool {
	ro, ok := driver.As[driver.ReadOnly](d)
	return ok && ro.ReadOnly(command)
}

func rejected(op string, r terminal.Response) error {
	return failure.New(failure.CodeRejected, op).Because(string(r.Reason()))
}

func closeError(err error) error {
	if err == nil || failure.Primary(err) == failure.CodeClosed || strings.Contains(err.Error(), "closed") {
		return nil
	}
	return failure.Wrap(failure.CodeClosed, "connector: close", err)
}

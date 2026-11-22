package terminal

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"reflect"
	"regexp"
	"slices"
	"strings"
	"sync/atomic"
	"time"

	"github.com/gatework/expect"
	"github.com/gatework/expect/record"
	"github.com/gatework/netops/failure"
	"github.com/gatework/netops/secret"
)

// Credentials are what a login may send.
type Credentials struct {
	Username string
	Password secret.Secret
	Enable   secret.Secret
}

// Options configure a Session.
type Options struct {
	// Timeout is the default bound of one command; zero means 2 minutes.
	Timeout time.Duration
	// MaxOutput bounds one response in bytes; zero means 64 MiB.
	MaxOutput int
	// Logger receives lifecycle events, never device output.
	Logger *slog.Logger
	// Recorder keeps the session transcript; nil records with the
	// EXPECT_RECORD_* environment defaults (on, under ~/.local/share/gatework/expect), and
	// record.Disabled() records nothing.
	Recorder *record.Recorder
	// Label names the device in transcripts and log attributes.
	Label string
	// Now is the clock; nil uses time.Now.
	Now func() time.Time
}

// Session is a CLI conversation over one stream. It is not safe for
// concurrent use: a call made while another runs fails with CodeBusy.
type Session struct {
	x       *expect.Session
	c       *compiled
	o       Options
	creds   Credentials
	busy    atomic.Bool
	prompts []modePrompt
	host    string
	mode    Mode
	prompt  string
	banner  string
}

type modePrompt struct {
	mode Mode
	re   *regexp.Regexp
}

// New takes ownership of stream on success. It validates the grammar and
// configures redaction before the expect reader can consume device output.
func New(stream io.ReadWriteCloser, g Grammar, creds Credentials, o Options) (*Session, error) {
	c, err := g.compile()
	if err != nil {
		return nil, failure.Wrap(failure.CodeInvalid, "terminal: grammar", err)
	}
	if o.Timeout <= 0 {
		o.Timeout = 2 * time.Minute
	}
	if o.MaxOutput <= 0 {
		o.MaxOutput = 64 << 20
	}
	if o.Logger == nil {
		o.Logger = slog.New(slog.DiscardHandler)
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	ending := g.LineEnding
	if ending == "" {
		ending = "\n"
	}
	opts := []expect.SessionOption{
		expect.WithLineEnding(ending), expect.WithBufferLimit(o.MaxOutput + (64 << 10)), expect.WithRemoveNulls(true),
		expect.WithLogger(o.Logger), expect.WithLabel(o.Label), expect.WithWindow(g.LineWidth(), 24),
	}
	if o.Recorder != nil {
		opts = append(opts, expect.WithRecorder(o.Recorder))
	}
	s := &Session{c: c, o: o, creds: creds}
	if err := s.pin(""); err != nil {
		return nil, err
	}
	if nilStream(stream) {
		return nil, failure.New(failure.CodeInternal, "terminal: nil stream")
	}
	input := &sessionStream{ReadWriteCloser: stream, ready: make(chan struct{})}
	x, err := expect.NewSession(input, opts...)
	if err != nil {
		return nil, failure.Wrap(failure.CodeInternal, "terminal: session", err)
	}
	err = registerRedaction(x, c.redact, creds)
	input.active = err == nil
	close(input.ready)
	if err != nil {
		return nil, errors.Join(failure.Wrap(failure.CodeInternal, "terminal: redact", err), x.Close())
	}
	s.x = x
	return s, nil
}

func registerRedaction(x *expect.Session, patterns []*regexp.Regexp, creds Credentials) error {
	for _, re := range patterns {
		if err := x.RedactPattern(re); err != nil {
			return err
		}
	}
	var secrets []string
	for _, v := range []string{creds.Password.Reveal(), creds.Enable.Reveal()} {
		if v != "" {
			secrets = append(secrets, v)
		}
	}
	if len(secrets) > 0 {
		return x.Redact(secrets...)
	}
	return nil
}

// sessionStream keeps read-ahead behind redaction setup. When setup fails,
// closing expect releases its pump without closing the caller's stream.
type sessionStream struct {
	io.ReadWriteCloser
	ready  chan struct{}
	active bool
}

func (s *sessionStream) Read(p []byte) (int, error) {
	<-s.ready
	if !s.active {
		return 0, io.ErrClosedPipe
	}
	return s.ReadWriteCloser.Read(p)
}

func (s *sessionStream) Close() error {
	if !s.active {
		return nil
	}
	return s.ReadWriteCloser.Close()
}

func (s *sessionStream) SetWriteDeadline(t time.Time) error {
	if stream, ok := s.ReadWriteCloser.(interface {
		SetWriteDeadline(deadline time.Time) error
	}); ok {
		return stream.SetWriteDeadline(t)
	}
	return errors.ErrUnsupported
}

func nilStream(stream io.ReadWriteCloser) bool {
	v := reflect.ValueOf(stream)
	switch v.Kind() { //nolint:exhaustive // only nil-capable stream types are relevant
	case reflect.Invalid:
		return true
	case reflect.Chan, reflect.Func, reflect.Map, reflect.Pointer, reflect.Slice:
		return v.IsNil()
	default:
		return false
	}
}

// Close ends the session and closes the stream.
func (s *Session) Close() error { return s.x.Close() }

// Host returns the hostname learned from the prompt.
func (s *Session) Host() string { return s.host }

// Mode returns the current mode.
func (s *Session) Mode() Mode { return s.mode }

// Prompt returns the last prompt.
func (s *Session) Prompt() string { return s.prompt }

// Banner returns the text received before the first prompt.
func (s *Session) Banner() string { return s.banner }

// LineWidth returns the terminal width the grammar asks for.
func (g Grammar) LineWidth() int {
	if g.Width > 0 {
		return g.Width
	}
	return 511
}

// stopError ends an Expect loop from a handler; err says why.
type stopError struct{ err error }

func (e *stopError) Error() string { return e.err.Error() }
func (e *stopError) Unwrap() error { return e.err }

func stop(code failure.Code, reason Reason) (expect.Action, error) {
	return expect.Return, &stopError{failure.New(code, "terminal").Because(string(reason))}
}

// Login authenticates, learns the hostname, escalates privilege when the
// grammar needs it and runs the preparation commands.
func (s *Session) Login(ctx context.Context) error {
	release, err := s.acquire()
	if err != nil {
		return err
	}
	defer release()
	if err := s.login(ctx); err != nil {
		return err
	}
	if p := s.c.g.Privilege; p != nil && s.mode == p.From {
		if err := s.escalate(ctx); err != nil {
			return err
		}
	}
	for _, text := range s.c.g.Preparation {
		r, err := s.run(ctx, Command{Text: text})
		if err != nil {
			return err
		}
		if !r.OK() {
			return failure.New(failure.CodeRejected, "terminal: prepare").Because(string(r.Reason()))
		}
	}
	return nil
}

// within counts an answer of rl and reports whether its limit allows it.
func within(rl Rule, answered map[string]int) bool {
	answered[rl.Name]++
	limit := rl.Limit
	if limit == 0 {
		limit = 1
	}
	return limit < 0 || answered[rl.Name] <= limit
}

// Enter moves the session to mode m.
func (s *Session) Enter(ctx context.Context, m Mode) error {
	release, err := s.acquire()
	if err != nil {
		return err
	}
	defer release()
	return s.enter(ctx, m)
}

// Run sends cmd in its mode and returns the device's answer. A command the
// device rejects returns a Rejected response and a nil error; the error is
// for failures that leave the session unusable or the outcome unknown.
func (s *Session) Run(ctx context.Context, cmd Command) (Response, error) {
	if err := cmd.Validate(); err != nil {
		return Response{}, failure.Wrap(failure.CodeInvalid, "terminal: command", err)
	}
	if _, err := compileRules(cmd.Rules); err != nil {
		return Response{}, failure.Wrap(failure.CodeInvalid, "terminal: command", err)
	}
	release, err := s.acquire()
	if err != nil {
		return Response{}, err
	}
	defer release()
	if err := s.enter(ctx, cmd.Mode); err != nil {
		return Response{}, err
	}
	return s.run(ctx, cmd)
}

func cmp(a, b time.Duration) time.Duration {
	if a > 0 {
		return a
	}
	return b
}

func echoes(line, cmd string) bool {
	line, cmd = strings.TrimSpace(line), strings.TrimSpace(cmd)
	return line != "" && (strings.HasSuffix(line, cmd) || strings.HasPrefix(cmd, line))
}

// Execute runs a procedure and requires affirmative evidence. A rejected
// step stops it.
func (s *Session) Execute(ctx context.Context, p Procedure) (Receipt, error) {
	if err := p.Validate(); err != nil {
		return Receipt{}, failure.Wrap(failure.CodeInvalid, "terminal: procedure", err)
	}
	p = p.clone()
	success, _ := compileSigs(p.Success)
	fail, _ := compileSigs(p.Failure)
	release, err := s.acquire()
	if err != nil {
		return Receipt{}, err
	}
	defer release()
	rec := Receipt{Procedure: p.Name}
	var body []string
	for _, step := range p.Steps {
		if err := s.enter(ctx, step.Mode); err != nil {
			return rec, err
		}
		r, err := s.run(ctx, step)
		if err != nil {
			return rec, err
		}
		rec.Responses = append(rec.Responses, r)
		body = append(body, r.Body...)
		if sg, ok := match(fail, strings.Join(body, "\n")); ok {
			return rec, failure.New(failure.CodeRejected, "terminal: "+p.Name).Because(string(sg.Reason))
		}
		if !r.OK() {
			return rec, failure.New(failure.CodeRejected, "terminal: "+p.Name).Because(string(r.Reason()))
		}
	}
	text := strings.Join(body, "\n")
	for _, sg := range success {
		m := sg.re.FindStringSubmatch(text)
		if m == nil {
			continue
		}
		rec.Evidence = sg.Reason
		for i, name := range sg.re.SubexpNames() {
			if name != "" && m[i] != "" {
				if rec.Values == nil {
					rec.Values = map[string]string{}
				}
				rec.Values[name] = m[i]
			}
		}
		return rec, nil
	}
	return rec, failure.New(failure.CodeUnconfirmed, "terminal: "+p.Name).Because(string(ReasonNoEvidence))
}

// String identifies the session without device data.
func (s *Session) String() string { return fmt.Sprintf("terminal.Session(%s)", s.mode) }

func (s *Session) acquire() (func(), error) {
	if !s.busy.CompareAndSwap(false, true) {
		return nil, failure.New(failure.CodeBusy, "terminal")
	}
	return func() { s.busy.Store(false) }, nil
}

// pin compiles the prompts for host ("" means any hostname).
func (s *Session) pin(host string) error {
	ps := make([]modePrompt, len(s.c.g.Prompts))
	for i, p := range s.c.g.Prompts {
		re, err := p.compile(host)
		if err != nil {
			return failure.Wrap(failure.CodeInvalid, "terminal: prompt", err)
		}
		ps[i] = modePrompt{mode: p.Mode, re: re}
	}
	s.prompts, s.host = ps, host
	return nil
}

func (s *Session) login(ctx context.Context) error {
	timeout := s.c.g.Login.Timeout
	if timeout <= 0 {
		timeout = 30 * time.Second
	}
	d := &loginDialogue{s: s, answered: map[string]int{}}
	cases := s.promptCases()
	n := len(cases)
	cases = append(cases, d.cases()...)
	r, err := s.x.Expect(ctx, cases, expect.WithTimeout(timeout))
	if err != nil {
		if errors.Is(err, expect.ErrTimeout) && d.sent() {
			// The device went silent after a credential: a refusal that
			// does not prompt again.
			_, err = d.refused()
		}
		return s.fail("terminal: login", err)
	}
	if r.CaseIndex >= n {
		return failure.New(failure.CodeProtocol, "terminal: login")
	}
	s.banner = d.text.String() + r.Before
	return s.arrive(r)
}

// loginDialogue is the state of one login: what was received and which
// credentials were already sent. Each is sent at most once.
type loginDialogue struct {
	s                *Session
	text             strings.Builder
	sentUser, sentPw bool
	answered         map[string]int
}

func (d *loginDialogue) sent() bool { return d.sentUser || d.sentPw }

func (d *loginDialogue) collect(r expect.Result) {
	d.text.WriteString(r.Before)
	d.text.WriteString(r.Match)
}

// refused classifies a refused login: locked, or a plain failure.
func (d *loginDialogue) refused() (expect.Action, error) {
	for _, line := range render(d.text.String()) {
		if _, ok := match(d.s.c.g.Login.Locked, line); ok {
			return stop(failure.CodeLocked, ReasonLocked)
		}
	}
	return stop(failure.CodeAuth, ReasonLoginFailed)
}

// credential answers a credential prompt once; a second prompt for the
// same credential is a refusal.
func (d *loginDialogue) credential(sent *bool, value func() string) expect.Handler {
	return func(ctx context.Context, x *expect.Session, r expect.Result) (expect.Action, error) {
		d.collect(r)
		v := value()
		if *sent || v == "" {
			return d.refused()
		}
		*sent = true
		_, err := x.SendLine(ctx, v)
		return expect.Continue, err
	}
}

func (d *loginDialogue) rule(rl Rule) expect.Handler {
	return func(ctx context.Context, _ *expect.Session, r expect.Result) (expect.Action, error) {
		d.collect(r)
		if !within(rl, d.answered) {
			return d.refused()
		}
		return expect.Continue, d.s.reply(ctx, rl.Reply)
	}
}

func (d *loginDialogue) cases() []expect.Case {
	s := d.s
	var cases []expect.Case
	user := d.credential(&d.sentUser, func() string { return s.creds.Username })
	for _, re := range s.c.user {
		cases = append(cases, expect.Case{Pattern: pattern(re), Handler: user})
	}
	pw := d.credential(&d.sentPw, s.creds.Password.Reveal)
	for _, re := range s.c.pass {
		cases = append(cases, expect.Case{Pattern: pattern(re), Handler: pw})
	}
	for _, rl := range slices.Concat(s.c.g.Login.Banner, s.c.g.Login.Expired) {
		cases = append(cases, expect.Case{Pattern: pattern(rl.re), Handler: d.rule(rl)})
	}
	return append(cases, expect.Case{Pattern: expect.EOF(), Handler: func(context.Context, *expect.Session, expect.Result) (expect.Action, error) {
		if d.sent() {
			return d.refused()
		}
		return stop(failure.CodeClosed, "")
	}})
}

func (s *Session) reply(ctx context.Context, r Reply) error {
	text := r.Text
	switch r.Secret {
	case SecretUsername:
		text = s.creds.Username
	case SecretPassword:
		text = s.creds.Password.Reveal()
	case SecretEnable:
		text = s.creds.Enable.Reveal()
	case NoSecret:
	}
	if r.Raw {
		_, err := s.x.Send(ctx, text)
		return err
	}
	_, err := s.x.SendLine(ctx, text)
	return err
}

// promptCases match prompts without including them in collected output.
func (s *Session) promptCases() []expect.Case {
	cases := make([]expect.Case, len(s.prompts))
	for i, p := range s.prompts {
		cases[i] = expect.Case{Pattern: pattern(p.re), Omit: true}
	}
	return cases
}

// arrive records the prompt a prompt case matched and learns the host.
func (s *Session) arrive(r expect.Result) error {
	p := s.prompts[r.CaseIndex]
	s.mode, s.prompt = p.mode, strings.TrimSpace(strings.Trim(r.Match, "\r\n\x00"))
	if s.host != "" {
		return nil
	}
	for _, c := range r.Captures {
		if c.Name == "host" && c.Matched && c.Text != "" {
			return s.pin(c.Text)
		}
	}
	return nil
}

func (s *Session) escalate(ctx context.Context) error {
	p := s.c.g.Privilege
	sent := false
	cases := s.promptCases()
	for _, re := range s.c.enable {
		cases = append(cases, expect.Case{Pattern: pattern(re), Omit: true, Handler: func(ctx context.Context, x *expect.Session, _ expect.Result) (expect.Action, error) {
			if sent || s.creds.Enable.Empty() {
				return stop(failure.CodeAuth, ReasonEnableFailed)
			}
			sent = true
			_, err := x.SendLine(ctx, s.creds.Enable.Reveal())
			return expect.Continue, err
		}})
	}
	if _, err := s.x.SendLine(ctx, p.Command); err != nil {
		return s.fail("terminal: enable", err)
	}
	r, err := s.x.Expect(ctx, cases, expect.WithTimeout(s.o.Timeout), expect.WithOutput())
	if err != nil {
		return s.fail("terminal: enable", err)
	}
	if err := s.arrive(r); err != nil {
		return err
	}
	for _, line := range render(r.Output) {
		if _, ok := match(p.Failed, line); ok {
			return failure.New(failure.CodeAuth, "terminal: enable").Because(string(ReasonEnableFailed))
		}
	}
	if s.mode == p.From {
		return failure.New(failure.CodeAuth, "terminal: enable").Because(string(ReasonEnableFailed))
	}
	return nil
}

func (s *Session) enter(ctx context.Context, m Mode) error {
	if m == ModeAny || m == s.mode || m == ModeConfigSub && s.mode == ModeConfig {
		return nil
	}
	if m.Configuring() {
		if p := s.c.g.Privilege; p != nil && s.mode == p.From {
			if err := s.escalate(ctx); err != nil {
				return err
			}
		}
		return s.transition(ctx, s.c.g.Config.Enter, m)
	}
	if s.mode.Configuring() {
		if err := s.transition(ctx, s.c.g.Config.Leave, m); err != nil {
			return err
		}
	}
	if p := s.c.g.Privilege; p != nil && m == ModePrivileged && s.mode == p.From {
		return s.escalate(ctx)
	}
	return nil
}

func (s *Session) transition(ctx context.Context, text string, want Mode) error {
	if text == "" {
		return failure.New(failure.CodeUnsupported, "terminal: mode")
	}
	r, err := s.run(ctx, Command{Text: text})
	if err != nil {
		return err
	}
	if !r.OK() {
		return failure.New(failure.CodeRejected, "terminal: mode").Because(string(r.Reason()))
	}
	if s.mode.Configuring() != want.Configuring() {
		return failure.New(failure.CodeProtocol, "terminal: mode")
	}
	return nil
}

func (s *Session) run(ctx context.Context, cmd Command) (Response, error) {
	rules, err := compileRules(cmd.Rules)
	if err != nil {
		return Response{}, failure.Wrap(failure.CodeInvalid, "terminal: command", err)
	}
	start := s.o.Now()
	x := &exchange{s: s, cmd: cmd, counts: map[string]int{}}
	cases := s.promptCases()
	n := len(cases)
	cases = append(cases, x.cases(slices.Concat(rules, s.c.g.Rules))...)
	opts := []expect.MatchOption{expect.WithTimeout(cmp(cmd.Timeout, s.o.Timeout)), expect.WithOutputLimit(s.o.MaxOutput)}
	if cmd.Idle > 0 {
		opts = append(opts, expect.WithIdleTimeout(cmd.Idle))
	}
	if _, err := s.x.SendLine(ctx, cmd.Text); err != nil {
		return Response{}, s.fail("terminal: send", err)
	}
	r, err := s.x.Expect(ctx, cases, opts...)
	if err != nil {
		return Response{}, s.failed(ctx, err)
	}
	if r.CaseIndex >= n {
		return Response{}, failure.New(failure.CodeProtocol, "terminal: command")
	}
	if err := s.arrive(r); err != nil {
		return Response{}, err
	}
	resp := s.response(cmd, r.Output, r.Match)
	resp.Answered, resp.Duration = x.answered, s.o.Now().Sub(start)
	return resp, nil
}

// abort cancels a pending question or output and waits briefly for the
// prompt so the session stays usable.
func (s *Session) abort(ctx context.Context) {
	key := s.c.g.Abort
	if key == "" {
		key = "\x03"
	}
	if _, err := s.x.Send(ctx, key); err != nil {
		return
	}
	if r, err := s.x.Expect(ctx, s.promptCases(), expect.WithTimeout(5*time.Second)); err == nil {
		_ = s.arrive(r)
	}
}

// response renders and classifies the output of cmd.
func (s *Session) response(cmd Command, raw, prompt string) Response {
	text, enc := decode([]byte(raw))
	lines := render(text)
	full := strings.Join(lines, "\n")
	if p := strings.TrimSpace(strings.Trim(prompt, "\r\n\x00")); p != "" {
		full = strings.TrimRight(full, "\n") + "\n" + p
	}
	// The first line is the echo of the command.
	if len(lines) > 0 && echoes(lines[0], cmd.Text) {
		lines = lines[1:]
	}
	resp := Response{Command: cmd.Text, Raw: full, Prompt: s.prompt, Mode: s.mode, Encoding: enc}
	if cmd.Sensitive {
		resp.Command, resp.Raw = secret.Mask, ""
	}
	for _, l := range lines {
		if anyMatch(s.c.async, l) {
			resp.Notices = append(resp.Notices, Issue{Reason: ReasonAsync, Line: len(resp.Body) + 1})
			continue
		}
		resp.Body = append(resp.Body, l)
		if sg, ok := match(s.c.errors, l); ok {
			resp.Issues = append(resp.Issues, Issue{Reason: sg.Reason, Line: len(resp.Body)})
		} else if sg, ok := match(s.c.warnings, l); ok {
			resp.Notices = append(resp.Notices, Issue{Reason: sg.Reason, Line: len(resp.Body)})
		}
	}
	for len(resp.Body) > 0 && strings.TrimSpace(resp.Body[len(resp.Body)-1]) == "" {
		resp.Body = resp.Body[:len(resp.Body)-1]
	}
	if len(resp.Issues) > 0 {
		resp.Verdict = Rejected
	}
	return resp
}

// fail classifies an expect error.
func (s *Session) fail(op string, err error) error {
	if _, ok := errors.AsType[*failure.Error](err); ok {
		return err
	}
	var code failure.Code
	switch {
	case errors.Is(err, context.Canceled):
		code = failure.CodeCancelled
	case errors.Is(err, context.DeadlineExceeded), errors.Is(err, expect.ErrTimeout), errors.Is(err, expect.ErrIdleTimeout):
		code = failure.CodeTimeout
	case errors.Is(err, expect.ErrBufferLimit):
		code = failure.CodeLimit
	case errors.Is(err, expect.ErrClosed), errors.Is(err, io.EOF), errors.Is(err, io.ErrClosedPipe):
		code = failure.CodeClosed
	default:
		if _, ok := errors.AsType[*expect.WriteError](err); ok {
			code = failure.CodeClosed
		} else {
			code = failure.CodeInternal
		}
	}
	return failure.Wrap(code, op, err)
}

// failed classifies a failed command and resynchronizes the session when
// the device may still be waiting on a question or streaming output.
func (s *Session) failed(ctx context.Context, err error) error {
	if errors.Is(err, expect.ErrIdleTimeout) {
		s.abort(ctx)
		return failure.Wrap(failure.CodeInteraction, "terminal: command", err).Because(string(ReasonStalled))
	}
	if errors.Is(err, expect.ErrOutputLimit) {
		s.abort(ctx)
		return failure.New(failure.CodeLimit, "terminal: response")
	}
	if code := failure.Primary(err); code == failure.CodeInteraction || code == failure.CodeLimit {
		s.abort(ctx)
	}
	return s.fail("terminal: command", err)
}

// exchange tracks the questions answered during one command.
type exchange struct {
	s        *Session
	cmd      Command
	answered []string
	counts   map[string]int
}

// pager answers a pager prompt.
func (x *exchange) pager(rl Rule) expect.Handler {
	return func(ctx context.Context, _ *expect.Session, _ expect.Result) (expect.Action, error) {
		return expect.Continue, x.s.reply(ctx, rl.Reply)
	}
}

// rule answers a known question within its risk and limit.
func (x *exchange) rule(rl Rule) expect.Handler {
	return func(ctx context.Context, _ *expect.Session, _ expect.Result) (expect.Action, error) {
		if rl.Risk > x.cmd.Allow {
			return stop(failure.CodeInteraction, ReasonDisruptive)
		}
		if !within(rl, x.counts) {
			return stop(failure.CodeInteraction, ReasonUnanswered)
		}
		x.answered = append(x.answered, rl.Name)
		return expect.Continue, x.s.reply(ctx, rl.Reply)
	}
}

// cases are, after the prompts: pagers, known questions, unknown
// questions (abort) and end of stream.
func (x *exchange) cases(rules []Rule) []expect.Case {
	var cases []expect.Case
	for _, rl := range x.s.c.g.Pager {
		cases = append(cases, expect.Case{Pattern: pattern(rl.re), Omit: true, Handler: x.pager(rl)})
	}
	for _, rl := range rules {
		cases = append(cases, expect.Case{Pattern: pattern(rl.re), Handler: x.rule(rl)})
	}
	for _, re := range x.s.c.questions {
		cases = append(cases, expect.Case{Pattern: pattern(re), Handler: func(context.Context, *expect.Session, expect.Result) (expect.Action, error) {
			return stop(failure.CodeInteraction, ReasonUnanswered)
		}})
	}
	return append(cases, expect.Case{Pattern: expect.EOF(), Handler: func(context.Context, *expect.Session, expect.Result) (expect.Action, error) {
		return stop(failure.CodeClosed, "")
	}})
}

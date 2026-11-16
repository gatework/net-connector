package connector

import (
	"context"
	"errors"
	"io"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	expect "github.com/gatework/go-expect"
)

// ExecuteCommand executes one validated command under the device operation lease.
func (d *Device) ExecuteCommand(ctx context.Context, c Command, opts ExecuteOptions) (Result, error) {
	return d.ExecuteScript(ctx, Script{Commands: []Command{c}}, opts)
}

// ExecuteScript validates the entire script before connecting and retains accepted steps on failure.
func (d *Device) ExecuteScript(ctx context.Context, script Script, opts ExecuteOptions) (Result, error) {
	s, e := script.clone()
	if e != nil {
		return Result{}, e
	}
	if opts.MaxOutputBytes < 0 || opts.PreserveSessionOnRejection {
		return Result{}, ErrInvalid
	}
	if e = d.acquire(); e != nil {
		return Result{}, e
	}
	defer d.release()
	ctx, cancel := d.operationContext(ctx)
	defer cancel()
	return d.execute(ctx, s, opts, nil)
}

var ansiColor = regexp.MustCompile(`\x1b\[[0-9;]*m`)

type execution struct {
	textMode     configTextMode
	attempts     []Attempt
	device       *Device
	values       map[string]string
	valuesMu     sync.Mutex
	bytes, limit int64
	strategy     ConfigStrategy
	rejection    *Response
}

type hookExecutor struct {
	execution *execution
	scope     *callScope
}

func (x *hookExecutor) Value(key string) string {
	x.execution.valuesMu.Lock()
	defer x.execution.valuesMu.Unlock()
	return x.execution.values[key]
}
func (x *hookExecutor) SetValue(key, value string) {
	x.execution.valuesMu.Lock()
	defer x.execution.valuesMu.Unlock()
	x.execution.values[key] = value
}
func (x *hookExecutor) Execute(ctx context.Context, c Command) (StepResult, error) {
	ctx, leave, e := x.scope.enter(ctx)
	if e != nil {
		return StepResult{}, e
	}
	defer leave()
	if e = c.validate(); e != nil {
		return StepResult{}, e
	}
	return x.execution.command(ctx, c.clone())
}
func (x *execution) hook(ctx context.Context, run func(Executor) error) (err error) {
	executor := &hookExecutor{execution: x, scope: newCallScope(ctx)}
	defer func() {
		if executor.scope.end() && err == nil {
			err = context.Canceled
		}
	}()
	return run(executor)
}
func (d *Device) execute(ctx context.Context, script Script, opts ExecuteOptions, strategy ConfigStrategy) (result Result, err error) {
	returned := false
	var rejection *Response
	defer func() {
		finalized := false
		defer func() {
			if !finalized {
				_ = d.closeResources()
			}
		}()
		if !returned {
			return
		}
		if e := d.log.scope(d.baseSecrets(), true); e != nil {
			err = joinFailures(err, newError("log_error", "logging", Command{}, e))
		}
		level, status := LogInfo, "completed"
		if err != nil {
			level, status = LogError, "failed"
		}
		if e := d.sessionEvent(ctx, "operation_complete", level, Command{}, status); e != nil {
			err = joinFailures(err, e)
		}
		if err == nil {
			err = ctx.Err()
		}
		if err != nil {
			if opts.PreserveSessionOnRejection && rejection != nil && ctx.Err() == nil && d.Connected() && pureDeviceRejection(err) {
				d.setPrompt(*rejection)
			} else {
				err = d.retireFailure(err)
			}
		}
		finalized = true
	}()
	result, rejection, err = d.runScript(ctx, script, opts, strategy)
	returned = true
	return
}
func pureDeviceRejection(err error) bool {
	// A joined observer, logging or cancellation failure must never qualify.
	e, ok := err.(*Error)                                         //nolint:errorlint // only the unwrapped top-level classification qualifies.
	return ok && e.Code == "device_error" && e.cause == ErrDevice //nolint:errorlint // the cause must be exactly ErrDevice, not a joined tree.
}

func (d *Device) runScript(ctx context.Context, script Script, opts ExecuteOptions, strategy ConfigStrategy) (result Result, rejection *Response, err error) {
	if len(script.Commands) == 0 {
		return result, nil, ctx.Err()
	}
	if err = d.connect(ctx); err != nil {
		return
	}
	x := &execution{textMode: opts.textMode, device: d, values: make(map[string]string), limit: d.config.MaxScriptOutputBytes, strategy: strategy}
	defer func() {
		result.attempts = slices.Clone(x.attempts)
		if len(x.attempts) == 1 {
			rejection = x.rejection
		}
	}()
	if opts.MaxOutputBytes > 0 {
		x.limit = opts.MaxOutputBytes
	}

	if !opts.SkipPrivilege {
		if err = d.ensurePrivilege(ctx); err != nil {
			return
		}
	}
	for _, original := range script.Commands {
		if err = ctx.Err(); err != nil {
			return
		}
		if err = x.run(ctx, original, opts, &result); err != nil {
			return
		}
	}
	return
}

// ensurePrivilege enters the privileged mode once per session, answering
// the privilege prompt with the enable password (or the login password).
func (d *Device) ensurePrivilege(ctx context.Context) error {
	if d.terminal.PrivilegeCommand == "" || d.privileged.Load() {
		return nil
	}
	secret := d.config.EnablePassword
	if secret == "" {
		secret = d.config.Password
	}
	ac, cancel := context.WithTimeout(ctx, d.config.LoginTimeout)
	defer cancel()
	if err := d.sendLine(ac, d.terminal.PrivilegeCommand+d.config.LineEnding, false); err != nil {
		return err
	}
	s, err := d.readResponse(ac, Command{}, d.terminal.PrivilegePrompt, d.loginInteractions(secret), true, false)
	if err != nil {
		return err
	}
	d.setPrompt(s.Response())
	d.privileged.Store(true)
	return nil
}

// run executes one script command: the driver may rewrite or skip it, then
// the observer and configuration strategy check the step, and the receipt
// and step callbacks see it. Completed steps are kept in result.
func (x *execution) run(ctx context.Context, original Command, opts ExecuteOptions, result *Result) error {
	d := x.device
	c := original
	if d.preparer != nil {
		var skip bool
		err := x.hook(ctx, func(ex Executor) error { var e error; c, skip, e = d.preparer.PrepareCommand(ctx, c, ex); return e })
		if err != nil {
			return newError("prepare_failed", "script", original, err)
		}
		if skip {
			return nil
		}
		if err = c.validate(); err != nil {
			return err
		}
	}
	step, err := x.command(ctx, c)
	if step.Response().RawPrompt() != "" {
		result.steps = append(result.steps, step)
	}
	if err == nil && d.observer != nil {
		if e := x.hook(ctx, func(ex Executor) error { return d.observer.AfterCommand(ctx, c, step, ex) }); e != nil {
			err = newError("after_command_failed", "script", c, e)
		}
	}
	if err == nil && x.strategy != nil {
		if e := x.hook(ctx, func(ex Executor) error { return x.strategy.Validate(ctx, c, step, ex) }); e != nil {
			err = configurationFailure(c, e)
		}
	}
	if step.Response().RawPrompt() != "" && opts.OnReceipt != nil {
		if e := opts.OnReceipt(ctx, step); e != nil {
			err = joinFailures(err, newError("receipt_callback_failed", "script", c, e))
		}
	}
	if err != nil {
		return err
	}
	if err = ctx.Err(); err != nil {
		return err
	}
	if opts.OnStep != nil {
		if e := opts.OnStep(ctx, step); e != nil {
			return newError("step_callback_failed", "script", c, e)
		}
	}
	return ctx.Err()
}

func (x *execution) command(ctx context.Context, c Command) (step StepResult, err error) {
	attempted := false
	written := 0
	var response Response
	defer func() {
		if attempted {
			x.attempts = append(x.attempts, Attempt{command: c.clone(), response: response, written: written, complete: response.RawPrompt() != "", err: err})
		}
	}()

	d := x.device
	if err = ctx.Err(); err != nil {
		return step, err
	}
	secrets, private := d.commandPrivacy(c)
	restore, e := d.log.push(secrets, private)
	if e != nil {
		return step, newError("log_error", "logging", c, e)
	}
	defer func() {
		if e := restore(); e != nil {
			err = joinFailures(err, newError("log_error", "logging", c, e))
		}
	}()
	if e := d.sessionEvent(ctx, "command_start", LogInfo, c, ""); e != nil {
		return step, e
	}
	defer func() {
		level, status := LogInfo, "response_received"
		if err != nil {
			level, status = LogError, "failed"
		}
		if e := d.sessionEvent(ctx, "command_complete", level, c, status); e != nil {
			err = joinFailures(err, e)
		}
	}()
	d.log.count = func(n int) { x.bytes += int64(n) }
	defer func() { d.log.count = nil }()
	if x.limit > 0 && x.bytes >= x.limit {
		return step, newError("script_output_limit_exceeded", "script", c, ErrScriptLimit)
	}
	cc, cancel := d.commandContext(ctx, c)
	defer cancel()
	started := time.Now()
	prompt, e := x.prompt(c)
	if e != nil {
		return step, e
	}
	attempted = true
	if err = d.sendLine(cc, c.Text+d.config.LineEnding, c.Poll); err != nil {
		if progress, ok := errors.AsType[*expect.WriteError](err); ok {
			written = progress.Written
		}
		return step, writeFailure("command", c, err)
	}
	written = len(c.Text) + len(d.config.LineEnding)
	replies := append(slices.Clone(c.Interactions), d.terminal.Interactions...)
	replies = append(replies, Interaction{Pattern: d.terminal.Pager, Reply: d.terminal.PagerResponse, Unlimited: true})
	step, err = d.readResponse(cc, c, prompt, replies, false, c.Poll)
	response = step.Response()
	step.duration = time.Since(started)
	if err != nil {
		return StepResult{}, err
	}
	return x.verify(cc, c, step, response)
}

// commandContext applies the command timeout, with polling disabling relative timing.
func (d *Device) commandContext(ctx context.Context, c Command) (context.Context, context.CancelFunc) {
	timeout := d.config.CommandTimeout
	if c.Timeout != nil {
		timeout = *c.Timeout
	}
	if c.Poll {
		timeout = 0
	}
	if timeout > 0 {
		return context.WithTimeout(ctx, timeout)
	}
	return ctx, func() {}
}

// commandPrivacy returns the secrets to mask while c runs, and whether its
// output is private.
func (d *Device) commandPrivacy(c Command) (secrets []string, private bool) {
	secrets = d.baseSecrets()
	if c.Sensitive {
		secrets = append(secrets, c.Text)
	}
	private = c.Sensitive || c.OutputSensitive
	for _, rules := range [][]Interaction{c.Interactions, d.terminal.Interactions} {
		for _, rule := range rules {
			private = private || rule.Sensitive
		}
	}
	return secrets, private
}

// prompt returns the prompt that ends c's response: the command's own, the
// configuration strategy's, or the terminal's command prompt.
func (x *execution) prompt(c Command) (expect.Pattern, error) {
	d := x.device
	prompt := c.Prompt
	if prompt.IsZero() {
		prompt = d.terminal.CommandPrompt
	}
	if x.strategy != nil && c.Prompt.IsZero() {
		var e error
		if prompt, e = x.strategy.MatchPrompt(c.Text, d.RawPrompt()); e != nil {
			return expect.Pattern{}, e
		}
		if e = prompt.ValidateText(); e != nil {
			return expect.Pattern{}, ErrIncomplete
		}
	}
	return prompt, nil
}

// verify converts the response text, enforces the output limits and
// rejects device error output; a rejection is kept for the caller.
func (x *execution) verify(cc context.Context, c Command, step StepResult, response Response) (StepResult, error) {
	d := x.device
	var diagnostic string
	var conversionErr error
	switch x.textMode {
	case configTextRendered:
		diagnostic, conversionErr = response.data.convert()
	case configTextBackupSource:
		diagnostic, conversionErr = response.data.convertBackup()
	case configTextPreserveInvalid:
		diagnostic, conversionErr = response.data.convert()
		if conversionErr != nil {
			diagnostic, conversionErr = response.data.convertOriginal()
		}
	default:
		diagnostic, conversionErr = response.data.convert()
	}
	if conversionErr != nil {
		return StepResult{}, newError("invalid_output_encoding", "parse", c, conversionErr)
	}
	if int64(len(step.response.data.output)) > d.config.MaxOutputBytes {
		return step, newError("output_limit_exceeded", "parse", c, ErrOutputLimit)
	}
	if len(d.terminal.CommandErrors) > 0 {
		if strings.Contains(diagnostic, "\x1b[") {
			diagnostic = ansiColor.ReplaceAllString(diagnostic, "")
		}
		diagnostic = strings.ReplaceAll(strings.ReplaceAll(diagnostic, "\r\n", "\n"), "\r", "\n")
	}
	rendered, _ := response.Rendered()
	for _, pattern := range d.terminal.CommandErrors {
		if pattern.MatchString(diagnostic) || pattern.MatchString(rendered) {
			if cc.Err() == nil && (x.limit <= 0 || x.bytes <= x.limit) {
				x.rejection = &response
			}
			return StepResult{}, newError("device_error", "command", c, ErrDevice)
		}
	}
	d.setPrompt(step.Response())
	if x.limit > 0 && x.bytes > x.limit {
		return step, newError("script_output_limit_exceeded", "script", c, ErrScriptLimit)
	}
	// The prompt handler records completion before a late cancellation is returned.
	if err := cc.Err(); err != nil {
		return step, err
	}
	return step, nil
}
func (d *Device) sendLine(ctx context.Context, text string, poll bool) error {
	if poll {
		_, e := d.session.SendAllPoll(ctx, text)
		return e
	}
	wc, cancel := context.WithTimeout(ctx, d.config.WriteTimeout)
	defer cancel()
	_, e := d.session.SendAll(wc, text)
	return e
}
func (d *Device) readResponse(ctx context.Context, c Command, prompt expect.Pattern, replies []Interaction, login, poll bool) (step StepResult, err error) {
	if prompt.IsZero() {
		return step, ErrInvalid
	}
	r := &responseRead{device: d, command: c, login: login, poll: poll}
	defer func() {
		step.command = c.clone()
		wire := r.raw.String()
		output := wire
		if r.separate {
			output = r.body.String()
		}
		step.response = Response{data: &responseData{raw: wire, rawPrompt: r.rawPrompt, output: output,
			outputErr: ErrIncomplete, renderErr: ErrIncomplete, promptErr: ErrIncomplete}}
	}()
	if login {
		r.addLoginFailures()
	}
	counts := make([]int, len(replies))
	for i, reply := range replies {
		if reply.Pattern.IsZero() {
			return step, ErrInvalid
		}
		r.add(reply.Pattern, r.replyHandler(reply, &counts[i]))
	}
	r.add(prompt, func(_ context.Context, _ *expect.Session, m expect.Result) (expect.Action, error) {
		if e := r.appendSegment(m, true); e != nil {
			return expect.Return, e
		}
		r.rawPrompt = m.Match
		r.completed = true
		return expect.Return, nil
	})
	options := []expect.MatchOption{expect.WithTimeout(0), expect.WithMatchOrder(expect.Declaration), expect.WithStreamingFallback(func(_ context.Context, _ *expect.Session, m expect.Result) (expect.Action, error) {
		return expect.ContinueKeepTimer, r.appendSegment(m, true)
	})}
	var final expect.Result
	if poll {
		final, err = d.session.Poll(ctx, r.cases, options...)
	} else {
		final, err = d.session.Expect(ctx, r.cases, options...)
	}
	if err != nil && !r.completed && final.CaseIndex < 0 && final.Before != "" {
		r.keepUnmatched(final.Before)
	}
	if err != nil && !r.completed {
		return StepResult{}, r.failure(err)
	}
	if r.completed {
		return step, nil
	}
	return step, err
}

// responseRead is the state of one readResponse call: the raw wire output,
// the response body (separate once a pager marker is removed) and the cases.
type responseRead struct {
	device      *Device
	command     Command
	login, poll bool
	raw, body   responseCollector
	rawPrompt   string
	separate    bool // body diverged from raw
	completed   bool // the prompt matched
	cases       []expect.Case
}

func (r *responseRead) add(p expect.Pattern, h expect.Handler) {
	r.cases = append(r.cases, expect.Case{Pattern: p, Handler: h})
}

// appendSegment records one matched segment. capture keeps the match in the
// body; otherwise (a removed pager marker) only its line delimiters are kept.
func (r *responseRead) appendSegment(m expect.Result, capture bool) error {
	if !capture && !r.separate {
		// Most responses never remove a pager marker: share raw until then.
		r.body = r.raw.clone()
		r.separate = true
	}
	r.raw.WriteString(m.Before)
	r.raw.WriteString(m.Match)
	if r.separate {
		r.body.WriteString(m.Before)
	}
	if capture {
		if r.separate {
			r.body.WriteString(m.Match)
		}
	} else {
		// Regex boundaries consume line delimiters that belong to the response; restore them.
		for _, b := range m.Match {
			if b == '\r' || b == '\n' {
				r.body.WriteRune(b)
			}
		}
	}
	if int64(r.raw.Len()) > r.device.config.MaxOutputBytes {
		return ErrOutputLimit
	}
	return nil
}

// addLoginFailures adds the cases that end a login with its failure cause.
func (r *responseRead) addLoginFailures() {
	for _, failure := range loginFailures {
		r.add(failure.pattern, func(context.Context, *expect.Session, expect.Result) (expect.Action, error) {
			return expect.Return, failure.cause
		})
	}
	r.add(loginAuthError, func(context.Context, *expect.Session, expect.Result) (expect.Action, error) {
		return expect.Return, ErrAuthentication
	})
	for _, re := range r.device.terminal.AuthenticationErrors {
		p, _ := expect.FromRegexp(re)
		r.add(p, func(context.Context, *expect.Session, expect.Result) (expect.Action, error) {
			return expect.Return, ErrAuthentication
		})
	}
}

// replyHandler answers one interaction prompt, at most its limit times (a
// login that loops is an authentication failure). Sensitive answers are
// masked in the log before they are sent.
func (r *responseRead) replyHandler(reply Interaction, count *int) expect.Handler {
	return func(hctx context.Context, _ *expect.Session, m expect.Result) (expect.Action, error) {
		if e := r.appendSegment(m, reply.Capture); e != nil {
			return expect.Return, e
		}
		*count++
		if !reply.Unlimited && *count > max(1, reply.Limit) {
			if r.login {
				return expect.Return, ErrAuthentication
			}
			return expect.Return, ErrResponseLimit
		}
		answer := reply.Reply
		if reply.Respond != nil {
			var e error
			if answer, e = reply.Respond(hctx, m.Match); e != nil {
				return expect.Return, e
			}
		}
		if reply.Sensitive {
			if e := r.device.log.protectReply(strings.TrimSuffix(answer, "\n")); e != nil {
				return expect.Return, e
			}
		}
		if e := hctx.Err(); e != nil {
			return expect.Return, e
		}
		if e := r.device.sendLine(hctx, answer, r.poll); e != nil {
			return expect.Return, writeFailure(r.phase(), r.command, e)
		}
		return expect.ContinueKeepTimer, nil
	}
}

func (r *responseRead) phase() string {
	if r.login {
		return "login"
	}
	return "command"
}

// keepUnmatched records the unmatched prefix that no handler or streaming
// fallback has seen, within the output limit.
func (r *responseRead) keepUnmatched(before string) {
	remaining := max(0, int(r.device.config.MaxOutputBytes)-r.raw.Len())
	prefix := before[:min(len(before), remaining)]
	if len(prefix) < len(before) {
		prefix = strings.Clone(prefix)
	}
	r.raw.WriteString(prefix)
	if r.separate {
		r.body.WriteString(prefix)
	}
}

// failure classifies a read that ended before the prompt. A classified
// *Error and cancellation pass through unchanged.
func (r *responseRead) failure(err error) error {
	if _, ok := errors.AsType[*Error](err); ok {
		return err
	}
	code := "transport_error"
	switch {
	case errors.Is(err, errConnectionRefused):
		code = "connection_refused"
	case errors.Is(err, errNoRoute):
		code = "no_route"
	case errors.Is(err, errConnectTimeout):
		code = "connection_timeout"
	case errors.Is(err, ErrResponseLimit):
		code = "response_limit_exceeded"
	case errors.Is(err, ErrAuthentication):
		code = "authentication_error"
	case errors.Is(err, ErrOutputLimit), errors.Is(err, expect.ErrBufferLimit):
		code = "output_limit_exceeded"
	case errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF):
		code = "connection_closed"
	case errors.Is(err, context.DeadlineExceeded), errors.Is(err, expect.ErrTimeout):
		switch {
		case !r.command.Prompt.IsZero():
			code = "prompt_error"
		case r.login:
			code = "login_timeout"
		default:
			code = "command_timeout"
		}
	case errors.Is(err, context.Canceled):
		return err
	}
	return newError(code, r.phase(), r.command, err)
}

func writeFailure(phase string, c Command, err error) error {
	if classified, ok := errors.AsType[*Error](err); ok {
		metadata := *classified
		metadata.cause = err
		return &metadata
	}
	if errors.Is(err, expect.ErrBufferLimit) || errors.Is(err, ErrOutputLimit) {
		return newError("output_limit_exceeded", phase, c, err)
	}
	code := "transport_error"
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, expect.ErrTimeout) {
		code = "write_timeout"
	}
	return newError(code, phase, c, err)
}

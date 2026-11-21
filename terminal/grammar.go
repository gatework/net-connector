package terminal

import (
	"fmt"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/gatework/expect"
)

// Mode is the CLI mode a prompt indicates.
type Mode uint8

// CLI modes. ModeAny on a Command means the command runs in whatever mode
// the session is in.
const (
	ModeAny        Mode = iota
	ModeUser            // Cisco ">", Comware "<host>"
	ModePrivileged      // Cisco "#"
	ModeConfig          // Cisco "(config)#", Comware "[host]", Junos "#"
	ModeConfigSub       // interface and other sub-views
)

var modeNames = [...]string{"any", "user", "privileged", "config", "config_sub"}

func (m Mode) String() string {
	if int(m) < len(modeNames) {
		return modeNames[m]
	}
	return fmt.Sprintf("mode(%d)", m)
}

// Configuring reports whether m is a configuration mode.
func (m Mode) Configuring() bool { return m == ModeConfig || m == ModeConfigSub }

// Risk grades what answering a question does.
type Risk uint8

// Risk levels.
const (
	// RiskRoutine answers are expected in normal operation: paging,
	// overwriting the startup file during a save, accepting a default file
	// name.
	RiskRoutine Risk = iota
	// RiskDisruptive answers interrupt service or lose data: reboot, reset
	// saved configuration, delete, erase, rollback.
	RiskDisruptive
)

// Reason is a stable, safe-to-report name of a device utterance, such as
// "invalid_input" or "save_ok". It never contains device output.
type Reason string

// Common reasons. Vendor grammars may define more.
const (
	ReasonInvalidInput  Reason = "invalid_input"
	ReasonIncomplete    Reason = "incomplete_command"
	ReasonAmbiguous     Reason = "ambiguous_command"
	ReasonWrongParam    Reason = "wrong_parameter"
	ReasonNotFound      Reason = "not_found"
	ReasonPermission    Reason = "permission_denied"
	ReasonBusy          Reason = "device_busy"
	ReasonCommandFailed Reason = "command_failed"
	ReasonLoginFailed   Reason = "login_failed"
	ReasonLocked        Reason = "account_locked"
	ReasonExpired       Reason = "password_expired"
	ReasonEnableFailed  Reason = "enable_failed"
	ReasonWarning       Reason = "warning"
	ReasonAsync         Reason = "async_log"
	ReasonUnanswered    Reason = "unanswered_question"
	ReasonDisruptive    Reason = "disruptive_question"
	ReasonStalled       Reason = "stalled"
	ReasonNoEvidence    Reason = "no_success_evidence"
)

// Signature is one recognizable device utterance. Pattern is a Go regular
// expression matched against single response lines (for Errors, Warnings
// and Async) or against the whole response (for Procedure evidence).
type Signature struct {
	Reason  Reason
	Pattern string
	re      *regexp.Regexp
}

// Sig declares a signature.
func Sig(reason Reason, pattern string) Signature { return Signature{Reason: reason, Pattern: pattern} }

// Secret names a credential a Reply sends.
type Secret uint8

// Credentials a Reply can send.
const (
	NoSecret Secret = iota
	SecretUsername
	SecretPassword
	SecretEnable
)

// Reply is how a Rule answers.
type Reply struct {
	// Text is sent followed by the line ending, unless Raw.
	Text string
	// Secret, when set, sends that credential instead of Text.
	Secret Secret
	// Raw sends Text without a line ending (single-key answers such as a
	// pager space or FortiGate's "a").
	Raw bool
}

// Answer returns a reply that sends text and a line ending.
func Answer(text string) Reply { return Reply{Text: text} }

// Key returns a reply that sends text without a line ending.
func Key(text string) Reply { return Reply{Text: text, Raw: true} }

// Enter returns a reply that accepts the offered default.
func Enter() Reply { return Reply{} }

// Rule answers one interactive question automatically.
type Rule struct {
	Name    string // stable name recorded in Response.Answered
	Pattern string // regular expression matched at the end of the received text
	Reply   Reply
	Risk    Risk
	// Limit is the number of answers per command; 0 means 1, negative
	// means unlimited (pagers only).
	Limit int
	re    *regexp.Regexp
}

// Host is the placeholder for the hostname in a Prompt expression.
const Host = "{host}"

// hostClass is what a hostname may contain before the session learns it.
const hostClass = `[^\s<>\[\]#()$%@]+`

// Prompt recognizes the prompt of one mode. Expr is a regular expression
// in which Host stands for the hostname (platforms whose prompt shows no
// hostname, such as Radware's ">> Main#", omit it); it may also define the groups
// "role" (HA state such as "active" or "M") and "pending" (uncommitted
// marker such as VRP's "*"). The expression matches the whole last line.
type Prompt struct {
	Mode Mode
	Expr string
}

func (p Prompt) compile(host string) (*regexp.Regexp, error) {
	h := `(?P<host>` + hostClass + `)`
	if host != "" {
		h = `(?P<host>` + regexp.QuoteMeta(host) + `)`
	}
	return regexp.Compile(`(?:^|[\r\n])[\x00 \t]*(?:` + strings.ReplaceAll(p.Expr, Host, h) + `)[ \t]*$`)
}

// Login is the authentication dialogue.
type Login struct {
	// Banner rules answer pre-login screens such as "Press RETURN".
	Banner []Rule
	// Username and Password match in-band credential prompts (Telnet, or
	// AAA asking again after SSH authentication).
	Username []string
	Password []string
	// Failed and Locked recognize a refused login.
	Failed []Signature
	Locked []Signature
	// Expired answers forced password-change questions, normally "N".
	Expired []Rule
	// Timeout bounds the whole login; zero means 30s.
	Timeout time.Duration
}

// Privilege is the escalation dialogue, such as Cisco "enable".
type Privilege struct {
	Command  string
	From     Mode // the mode that needs escalation, normally ModeUser
	Password []string
	Failed   []Signature
}

// ConfigMode enters and leaves configuration mode.
type ConfigMode struct {
	Enter string // "configure terminal", "system-view", "configure private"
	Leave string // "end", "return", "exit"
}

// Grammar is a device dialect. It is plain data: vendors compose it from
// shared fragments and Validate compiles it.
type Grammar struct {
	// LineEnding terminates sent lines; empty means "\n".
	LineEnding string
	// Width is the terminal width requested from the transport; 0 means 511.
	Width       int
	Login       Login
	Prompts     []Prompt
	Privilege   *Privilege
	Config      ConfigMode
	Preparation []string
	// Pager rules answer "--More--" and similar when paging cannot be
	// disabled. Their text is removed from responses.
	Pager []Rule
	// Errors are response lines that mean the command was rejected.
	Errors []Signature
	// Warnings are response lines kept as notices.
	Warnings []Signature
	// Async are asynchronous log lines removed from responses.
	Async []string
	// Questions are generic question shapes. Text at the end of the stream
	// that matches one and no Rule is an unanticipated question.
	Questions []string
	// Rules answer known confirmations.
	Rules []Rule
	// Abort is sent to cancel an unanswered question; empty means Ctrl-C.
	Abort string
	// Redact are regular expressions whose submatches (or whole matches)
	// are masked in session transcripts, for secrets the device prints in
	// configuration ("password cipher (\S+)"). Results keep the raw text.
	Redact []string
}

// compiled is a validated Grammar.
type compiled struct {
	g         Grammar
	errors    []Signature
	warnings  []Signature
	async     []*regexp.Regexp
	questions []*regexp.Regexp
	user      []*regexp.Regexp
	pass      []*regexp.Regexp
	enable    []*regexp.Regexp
	redact    []*regexp.Regexp
}

// Validate checks and compiles the grammar.
func (g Grammar) Validate() error {
	_, err := g.compile()
	return err
}

func (g Grammar) compile() (*compiled, error) {
	if len(g.Prompts) == 0 {
		return nil, fmt.Errorf("terminal: grammar has no prompts")
	}
	for _, p := range g.Prompts {
		if _, err := p.compile(""); err != nil {
			return nil, fmt.Errorf("terminal: prompt %q: %w", p.Expr, err)
		}
	}
	c := &compiled{g: g}
	var err error
	if c.errors, err = compileSigs(g.Errors); err != nil {
		return nil, err
	}
	if c.warnings, err = compileSigs(g.Warnings); err != nil {
		return nil, err
	}
	c.g.Login.Failed, err = compileSigs(g.Login.Failed)
	if err != nil {
		return nil, err
	}
	c.g.Login.Locked, err = compileSigs(g.Login.Locked)
	if err != nil {
		return nil, err
	}
	if c.async, err = compileAll(g.Async, ""); err != nil {
		return nil, err
	}
	if c.redact, err = compileAll(g.Redact, ""); err != nil {
		return nil, err
	}
	for _, set := range []struct {
		in  []string
		out *[]*regexp.Regexp
	}{{g.Questions, &c.questions}, {g.Login.Username, &c.user}, {g.Login.Password, &c.pass}} {
		if *set.out, err = compileAll(set.in, tail); err != nil {
			return nil, err
		}
	}
	if g.Privilege != nil {
		if g.Privilege.Command == "" {
			return nil, fmt.Errorf("terminal: privilege without command")
		}
		if c.enable, err = compileAll(g.Privilege.Password, tail); err != nil {
			return nil, err
		}
		p := *g.Privilege
		if p.Failed, err = compileSigs(p.Failed); err != nil {
			return nil, err
		}
		c.g.Privilege = &p
	}
	for _, rs := range []*[]Rule{&c.g.Pager, &c.g.Rules, &c.g.Login.Banner, &c.g.Login.Expired} {
		if *rs, err = compileRules(*rs); err != nil {
			return nil, err
		}
	}
	return c, nil
}

// tail anchors a question pattern at the end of the received text: a
// question is only a question while the device waits on it.
const tail = `[ \t]*$`

func compileAll(exprs []string, suffix string) ([]*regexp.Regexp, error) {
	out := make([]*regexp.Regexp, len(exprs))
	for i, e := range exprs {
		re, err := regexp.Compile(e + suffix)
		if err != nil {
			return nil, fmt.Errorf("terminal: pattern %q: %w", e, err)
		}
		out[i] = re
	}
	return out, nil
}

func compileSigs(in []Signature) ([]Signature, error) {
	out := slices.Clone(in)
	for i := range out {
		if out[i].Reason == "" {
			return nil, fmt.Errorf("terminal: signature %q has no reason", out[i].Pattern)
		}
		re, err := regexp.Compile(out[i].Pattern)
		if err != nil {
			return nil, fmt.Errorf("terminal: signature %s: %w", out[i].Reason, err)
		}
		out[i].re = re
	}
	return out, nil
}

func compileRules(in []Rule) ([]Rule, error) {
	out := slices.Clone(in)
	for i := range out {
		if out[i].Name == "" {
			return nil, fmt.Errorf("terminal: rule %q has no name", out[i].Pattern)
		}
		re, err := regexp.Compile(out[i].Pattern + tail)
		if err != nil {
			return nil, fmt.Errorf("terminal: rule %s: %w", out[i].Name, err)
		}
		out[i].re = re
	}
	return out, nil
}

// match returns the first signature whose pattern matches s.
func match(sigs []Signature, s string) (Signature, bool) {
	for _, sg := range sigs {
		if sg.re.MatchString(s) {
			return sg, true
		}
	}
	return Signature{}, false
}

func anyMatch(res []*regexp.Regexp, s string) bool {
	return slices.ContainsFunc(res, func(re *regexp.Regexp) bool { return re.MatchString(s) })
}

func pattern(re *regexp.Regexp) expect.Pattern {
	p, err := expect.FromRegexp(re)
	if err != nil {
		panic("terminal: compiled pattern rejected: " + err.Error())
	}
	return p
}

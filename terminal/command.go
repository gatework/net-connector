package terminal

import (
	"fmt"
	"slices"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// Command is one line sent to the device.
type Command struct {
	Text string
	// Sensitive commands carry a secret; their text is redacted from
	// diagnostics and from the response echo.
	Sensitive bool
	// Rules answer questions specific to this command, before the
	// grammar's rules.
	Rules []Rule
	// Allow is the highest risk this command may answer.
	Allow Risk
	// Mode is the mode the command needs; the session enters it first.
	Mode Mode
	// Timeout bounds the whole command; zero uses the session default.
	Timeout time.Duration
	// Idle bounds the silence between two chunks of output; zero means
	// no separate bound.
	Idle time.Duration
}

// Validate rejects text that cannot be sent as one line.
func (c Command) Validate() error {
	switch {
	case strings.TrimSpace(c.Text) == "":
		return fmt.Errorf("terminal: empty command")
	case !utf8.ValidString(c.Text):
		return fmt.Errorf("terminal: command is not UTF-8")
	case strings.ContainsFunc(c.Text, func(r rune) bool { return r != '\t' && unicode.IsControl(r) }):
		return fmt.Errorf("terminal: command contains control characters")
	}
	for _, r := range c.Rules {
		if r.Name == "" {
			return fmt.Errorf("terminal: command rule without a name")
		}
	}
	return nil
}

// Verdict is the device's answer to a command.
type Verdict uint8

// Verdicts.
const (
	Accepted Verdict = iota
	Rejected
)

func (v Verdict) String() string {
	if v == Rejected {
		return "rejected"
	}
	return "accepted"
}

// Issue is a response line a signature recognized. Line is 1-based within
// Response.Body.
type Issue struct {
	Reason Reason `json:"reason"`
	Line   int    `json:"line"`
}

// Response is the device's answer to one command.
type Response struct {
	Command string `json:"command"`
	// Raw is the whole exchange as a screen shows it: the echo, the
	// answer and the closing prompt, decoded to UTF-8 with control
	// sequences rendered. It is empty for sensitive commands.
	Raw string `json:"-"`
	// Body is the answer without echo, prompt, pager and asynchronous log
	// lines.
	Body []string `json:"-"`
	// Prompt is the prompt the device returned to, and Mode its mode.
	Prompt string `json:"prompt"`
	Mode   Mode   `json:"mode"`
	// Verdict and Issues tell whether an error signature matched.
	Verdict Verdict `json:"verdict"`
	Issues  []Issue `json:"issues,omitempty"`
	// Notices are warnings and asynchronous log lines.
	Notices []Issue `json:"notices,omitempty"`
	// Answered names the rules that answered questions, in order.
	Answered []string `json:"answered,omitempty"`
	// Encoding is the source encoding of the output ("utf-8", "gb18030").
	Encoding string        `json:"encoding"`
	Duration time.Duration `json:"duration"`
}

// Text returns Body joined by newlines.
func (r Response) Text() string { return strings.Join(r.Body, "\n") }

// OK reports whether the command was accepted.
func (r Response) OK() bool { return r.Verdict == Accepted }

// Reason returns the reason of the first issue, or "".
func (r Response) Reason() Reason {
	if len(r.Issues) == 0 {
		return ""
	}
	return r.Issues[0].Reason
}

// Procedure is a long-running operation whose success needs affirmative
// evidence: save, commit, checkpoint, file transfer.
type Procedure struct {
	Name  string
	Steps []Command
	// Success signatures are matched against the whole output of all
	// steps; one must match. Named groups become Receipt.Values.
	Success []Signature
	// Failure signatures, checked first, fail the procedure.
	Failure []Signature
}

// Validate checks the procedure.
func (p Procedure) Validate() error {
	if p.Name == "" || len(p.Steps) == 0 || len(p.Success) == 0 {
		return fmt.Errorf("terminal: procedure %q needs steps and success evidence", p.Name)
	}
	for _, s := range p.Steps {
		if err := s.Validate(); err != nil {
			return fmt.Errorf("terminal: procedure %s: %w", p.Name, err)
		}
	}
	if _, err := compileSigs(p.Success); err != nil {
		return err
	}
	_, err := compileSigs(p.Failure)
	return err
}

// Receipt is the evidence a Procedure succeeded.
type Receipt struct {
	Procedure string            `json:"procedure"`
	Evidence  Reason            `json:"evidence"`
	Values    map[string]string `json:"values,omitempty"`
	Responses []Response        `json:"responses"`
}

func (p Procedure) clone() Procedure {
	p.Steps = slices.Clone(p.Steps)
	p.Success = slices.Clone(p.Success)
	p.Failure = slices.Clone(p.Failure)
	return p
}

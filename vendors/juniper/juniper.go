// Package juniper implements the Junos platform.
package juniper

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/gatework/net-connector/driver"
	"github.com/gatework/net-connector/terminal"
	"github.com/gatework/net-connector/vendors/internal/family"
)

// Junos is a Junos device.
type Junos struct {
	driver.Base
	family.ConfigRead
	driver.Verbs
	driver.Matcher
}

var (
	_ driver.Committer    = Junos{}
	_ driver.ConfigReader = Junos{}
)

// Grammar is the Junos dialect: "user@host>" operational and
// "user@host#" configuration prompts.
func Grammar() terminal.Grammar {
	g := family.Grammar([]terminal.Prompt{
		{Mode: terminal.ModePrivileged, Expr: `[^\s@]+@` + terminal.Host + `>`},
		{Mode: terminal.ModeConfig, Expr: `[^\s@]+@` + terminal.Host + `#`},
	}, []terminal.Signature{
		terminal.Sig(terminal.ReasonInvalidInput, `(?i)^\s*(?:syntax error|unknown command)`),
		terminal.Sig(terminal.ReasonIncomplete, `(?i)^\s*missing argument`),
		terminal.Sig(terminal.ReasonPermission, `(?i)^\s*permission denied`),
		terminal.Sig(terminal.ReasonCommandFailed, `(?i)^\s*error:`),
	})
	g.Config = terminal.ConfigMode{Enter: "configure exclusive", Leave: "exit configuration-mode"}
	g.Preparation = []string{"set cli screen-length 0", "set cli screen-width 0"}
	g.Rules = []terminal.Rule{
		// Leaving an exclusive candidate discards it; that is the intended
		// cleanup after a failed commit.
		{Name: "discard_uncommitted", Pattern: `(?i)Exit with uncommitted changes\? \[yes,no\] \(yes\)`, Reply: terminal.Answer("yes")},
	}
	g.Questions = append(g.Questions, `(?i)\[yes,no\](?: \((?:yes|no)\))?\s*`)
	return g
}

// New returns the Junos platform.
func New() Junos {
	return Junos{
		Base:       driver.NewBase("juniper", Grammar()),
		ConfigRead: family.Read("show configuration | display set | no-more"),
		Verbs:      driver.Verbs{"show", "ping", "traceroute"},
		Matcher:    driver.Matcher{Vendor: regexp.MustCompile(`\bjuniper\b`), OS: regexp.MustCompile(`^junos$`)},
	}
}

// CommitProcedure loads body into an exclusive candidate, checks it and
// commits; with Confirm it commits with automatic rollback and confirms.
func (Junos) CommitProcedure(body []string, o driver.CommitOptions) (terminal.Procedure, error) {
	if len(body) == 0 || o.Confirm < 0 || o.Confirm > 60 {
		return terminal.Procedure{}, fmt.Errorf("%w: commit body or confirm minutes", driver.ErrUnsupported)
	}
	steps := []terminal.Command{{Text: "configure exclusive", Mode: terminal.ModePrivileged}}
	for _, l := range body {
		steps = append(steps, terminal.Command{Text: l, Mode: terminal.ModeConfig})
	}
	steps = append(steps, terminal.Command{Text: "commit check", Timeout: 5 * time.Minute})
	commit := "commit"
	if o.Comment != "" {
		if strings.ContainsAny(o.Comment, "\"\\") {
			return terminal.Procedure{}, fmt.Errorf("%w: commit comment", driver.ErrUnsupported)
		}
		commit += " comment " + strconv.Quote(o.Comment)
	}
	if o.Confirm > 0 {
		steps = append(steps, terminal.Command{Text: "commit confirmed " + strconv.Itoa(o.Confirm), Timeout: 5 * time.Minute})
	}
	steps = append(steps,
		terminal.Command{Text: commit, Timeout: 5 * time.Minute},
		terminal.Command{Text: "exit configuration-mode"})
	return terminal.Procedure{
		Name:    "commit",
		Steps:   steps,
		Success: []terminal.Signature{terminal.Sig("commit_ok", `(?im)^\s*commit complete\s*$`)},
		Failure: []terminal.Signature{
			terminal.Sig("commit_check_failed", `(?i)configuration check-out failed|commit failed`),
			terminal.Sig("candidate_locked", `(?i)configuration database (?:locked|modified)`),
		},
	}, nil
}

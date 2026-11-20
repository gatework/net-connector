// Package paloalto implements the PAN-OS platform ("palo_alto").
package paloalto

import (
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/gatework/net-connector/driver"
	"github.com/gatework/net-connector/terminal"
	"github.com/gatework/net-connector/vendors/internal/family"
)

// PANOS is a PAN-OS firewall.
type PANOS struct {
	driver.Base
	driver.Verbs
	driver.Matcher
}

var (
	_ driver.Committer      = PANOS{}
	_ driver.ConfigReader   = PANOS{}
	_ driver.LoginInspector = PANOS{}
)

// configTimeout bounds "show" of a large rule base.
const configTimeout = 10 * time.Minute

const role = `(?:\((?P<role>[^)\r\n]+)\))?`

// Grammar is the PAN-OS dialect: "admin@fw(active)>" and "#".
func Grammar() terminal.Grammar {
	g := family.Grammar([]terminal.Prompt{
		{Mode: terminal.ModePrivileged, Expr: `[^\s@]+@` + terminal.Host + role + `>`},
		{Mode: terminal.ModeConfig, Expr: `[^\s@]+@` + terminal.Host + role + `#`},
	}, []terminal.Signature{
		terminal.Sig(terminal.ReasonInvalidInput, `(?i)^\s*(?:Invalid syntax|Unknown command)`),
		terminal.Sig(terminal.ReasonCommandFailed, `(?i)^\s*(?:Server error|Command failed)`),
	})
	g.Login.Banner = append(g.Login.Banner, terminal.Rule{
		Name: "acknowledge_banner", Pattern: `(?is)(?:acknowledge|accept).*(?:yes/no|\[y/n\]|enter\s+yes)[^\r\n]*`, Reply: terminal.Answer("yes"),
	})
	g.Config = terminal.ConfigMode{Enter: "configure", Leave: "exit"}
	g.Preparation = []string{"set cli pager off"}
	g.Rules = []terminal.Rule{
		{Name: "exit_uncommitted", Pattern: `(?i)Exit with uncommitted changes\?\s*\(y(?:es)?(?:\s+or\s+|/)n(?:o)?\)`, Reply: terminal.Answer("y")},
	}
	return g
}

// New returns the PAN-OS platform.
func New() PANOS {
	return PANOS{
		Base:    driver.NewBase("palo_alto", Grammar()),
		Verbs:   driver.Verbs{"show", "ping", "traceroute"},
		Matcher: driver.Matcher{Vendor: regexp.MustCompile(`palo\s*alto|paloalto`)},
	}
}

var roleRe = regexp.MustCompile(`\(([^)\r\n]+)\)[>#]\s*$`)

// AfterLogin reads the HA state from the prompt; a passive or suspended
// member must not be changed.
func (PANOS) AfterLogin(_, prompt string) (driver.LoginState, error) {
	st := driver.LoginState{Writable: true}
	if m := roleRe.FindStringSubmatch(prompt); m != nil {
		st.Role = strings.ToLower(m[1])
		st.Writable = st.Role == "active" || st.Role == "active-primary" || st.Role == "active-secondary"
	}
	return st, nil
}

// CommitProcedure loads body in configuration mode and commits. PAN-OS
// has no confirmed commit; the candidate outlives the session.
func (PANOS) CommitProcedure(body []string, o driver.CommitOptions) (terminal.Procedure, error) {
	if len(body) == 0 || o.Confirm != 0 {
		return terminal.Procedure{}, fmt.Errorf("%w: PAN-OS commit needs a body and has no confirmed commit", driver.ErrUnsupported)
	}
	steps := []terminal.Command{{Text: "configure", Mode: terminal.ModePrivileged}}
	for _, l := range body {
		steps = append(steps, terminal.Command{Text: l, Mode: terminal.ModeConfig})
	}
	commit := "commit"
	if o.Comment != "" {
		if strings.ContainsAny(o.Comment, "\"\\") {
			return terminal.Procedure{}, fmt.Errorf("%w: commit comment", driver.ErrUnsupported)
		}
		commit += ` description "` + o.Comment + `"`
	}
	steps = append(steps, terminal.Command{Text: commit, Timeout: 10 * time.Minute}, terminal.Command{Text: "exit"})
	return terminal.Procedure{
		Name:    "commit",
		Steps:   steps,
		Success: []terminal.Signature{terminal.Sig("commit_ok", `(?im)^\s*Configuration committed successfully\s*$`)},
		Failure: []terminal.Signature{terminal.Sig("commit_failed", `(?i)commit failed|Commit job \d+ .*fail|Validation Error`)},
	}, nil
}

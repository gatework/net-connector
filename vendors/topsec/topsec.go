// Package topsec implements the Topsec firewall platform.
package topsec

import (
	"regexp"

	"github.com/gatework/net-connector/driver"
	"github.com/gatework/net-connector/terminal"
	"github.com/gatework/net-connector/vendors/internal/family"
)

// TOS is a Topsec firewall.
type TOS struct {
	driver.Base
	family.ConfigRead
	driver.Verbs
	driver.Matcher
}

var _ driver.ConfigReader = TOS{}

// Grammar is the Topsec dialect: "host#", the hostname may be empty.
func Grammar() terminal.Grammar {
	return family.Grammar([]terminal.Prompt{
		{Mode: terminal.ModePrivileged, Expr: `(?:` + terminal.Host + `)?#`},
	}, []terminal.Signature{
		terminal.Sig(terminal.ReasonInvalidInput, `(?i)^\s*(?:%\s*)?(?:Unknown|Invalid) command`),
		terminal.Sig(terminal.ReasonIncomplete, `(?i)^\s*(?:%\s*)?Incomplete command`),
		terminal.Sig(terminal.ReasonAmbiguous, `(?i)^\s*(?:%\s*)?Ambiguous command`),
		terminal.Sig(terminal.ReasonPermission, `(?i)^\s*Permission denied`),
		terminal.Sig(terminal.ReasonCommandFailed, `(?i)^\s*Error:`),
	})
}

// New returns the Topsec platform.
func New() TOS {
	return TOS{
		Base:       driver.NewBase("topsec", Grammar()),
		ConfigRead: family.Read("show-running nostop"),
		Verbs:      driver.Verbs{"show", "show-running"},
		Matcher:    driver.Matcher{Vendor: regexp.MustCompile(`\btopsec\b`)},
	}
}

// Package fortinet implements the FortiGate FortiOS platform.
package fortinet

import (
	"regexp"
	"time"

	"github.com/gatework/net-connector/driver"
	"github.com/gatework/net-connector/terminal"
	"github.com/gatework/net-connector/vendors/internal/family"
)

// FortiOS is a FortiGate. FortiOS saves changes when a "config" block
// ends, so it declares no Saver.
type FortiOS struct {
	driver.Base
	family.ConfigRead
	driver.Verbs
	driver.Matcher
}

var _ driver.ConfigReader = FortiOS{}

// Grammar is the FortiOS dialect: "FGT #", "FGT (vdom) #", "FGT (interface) #".
func Grammar() terminal.Grammar {
	g := family.Grammar([]terminal.Prompt{
		{Mode: terminal.ModeConfigSub, Expr: terminal.Host + `[ \t]+\((?P<ctx>[^)\r\n]+)\)[ \t]*[#$]`},
		{Mode: terminal.ModePrivileged, Expr: terminal.Host + `[ \t]*[#$]`},
	}, []terminal.Signature{
		terminal.Sig(terminal.ReasonInvalidInput, `(?i)^\s*(?:command parse error|Unknown action|Unknown command)`),
		terminal.Sig(terminal.ReasonCommandFailed, `(?i)^\s*Command fail\.`),
		terminal.Sig(terminal.ReasonPermission, `(?i)^\s*(?:Permission denied|Access denied|Sorry, you have no permission)`),
	})
	g.Login.Banner = append(g.Login.Banner, terminal.Rule{Name: "press_any_key", Pattern: `(?i)Press any key to continue[^\r\n]*`, Reply: terminal.Key(" ")},
		terminal.Rule{Name: "accept_disclaimer", Pattern: `(?i)\(Press 'a' to accept\)\s*:?`, Reply: terminal.Key("a")})
	return g
}

// New returns the FortiOS platform.
func New() FortiOS {
	return FortiOS{
		Base:       driver.NewBase("fortinet", Grammar()),
		ConfigRead: family.ConfigRead{Command: family.Command("show full-configuration", 10*time.Minute)},
		Verbs:      driver.Verbs{"get", "show"},
		Matcher: driver.Matcher{Any: []driver.Matcher{
			{Vendor: regexp.MustCompile(`\bfortigate\b`)},
			{Vendor: regexp.MustCompile(`\bfortinet\b`), OS: regexp.MustCompile(`^fortios$`)},
			{Vendor: regexp.MustCompile(`\bfortinet\b`), Model: regexp.MustCompile(`^(?:fortigate|fgt)\s*\d`)},
		}},
	}
}

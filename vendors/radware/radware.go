// Package radware implements the Radware Alteon platform.
package radware

import (
	"regexp"
	"strings"

	"github.com/gatework/net-connector/driver"
	"github.com/gatework/net-connector/terminal"
	"github.com/gatework/net-connector/vendors/internal/family"
)

// Alteon is a Radware Alteon load balancer.
type Alteon struct {
	driver.Base
	family.ConfigRead
	driver.Matcher
}

var (
	_ driver.ConfigReader   = Alteon{}
	_ driver.LoginInspector = Alteon{}
	_ driver.ReadOnly       = Alteon{}
)

// Grammar is the Alteon menu dialect: ">> Main#", no hostname.
func Grammar() terminal.Grammar {
	g := family.Grammar([]terminal.Prompt{
		{Mode: terminal.ModePrivileged, Expr: `>> [^\r\n#]*#`},
	}, []terminal.Signature{
		terminal.Sig(terminal.ReasonInvalidInput, `(?i)^\s*(?:Unknown|Invalid) command`),
		terminal.Sig(terminal.ReasonCommandFailed, `(?i)^\s*Error`),
	})
	g.Login.Banner = append(g.Login.Banner, terminal.Rule{Name: "confirm_note", Pattern: `(?i)Confirm seeing above note \[y\]:`, Reply: terminal.Answer("y")})
	g.Rules = []terminal.Rule{
		{Name: "no_private_keys", Pattern: `(?i)Display private keys\? \[y/n\]:`, Reply: terminal.Answer("n")},
		{Name: "confirm_note", Pattern: `(?i)Confirm seeing above note \[y\]:`, Reply: terminal.Answer("y")},
	}
	return g
}

// New returns the Alteon platform.
func New() Alteon {
	return Alteon{
		Base:       driver.NewBase("radware", Grammar()),
		ConfigRead: family.Read("/cfg/dump"),
		Matcher:    driver.Matcher{Vendor: regexp.MustCompile(`\bradware\b`)},
	}
}

// ReadOnly accepts the /info and /stats menus and /cfg/dump.
func (Alteon) ReadOnly(command string) bool {
	c := strings.TrimSpace(command)
	return c == "/cfg/dump" || strings.HasPrefix(c, "/info") || strings.HasPrefix(c, "/stats")
}

var haState = regexp.MustCompile(`(?im)^\s*HA\s+State:\s*(\S+)`)

// AfterLogin reads the HA state from the login banner; only the active
// member is writable.
func (Alteon) AfterLogin(banner, _ string) (driver.LoginState, error) {
	st := driver.LoginState{Writable: true}
	if m := haState.FindStringSubmatch(banner); m != nil {
		st.Role = strings.ToLower(m[1])
		st.Writable = st.Role == "active" || st.Role == "master"
	}
	return st, nil
}

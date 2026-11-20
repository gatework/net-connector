// Package hillstone implements the Hillstone StoneOS platform.
package hillstone

import (
	"regexp"
	"time"

	"github.com/gatework/net-connector/driver"
	"github.com/gatework/net-connector/terminal"
	"github.com/gatework/net-connector/vendors/internal/family"
)

// StoneOS is a Hillstone firewall.
type StoneOS struct {
	driver.Base
	family.ConfigRead
	driver.Verbs
	driver.Matcher
}

var (
	_ driver.Saver          = StoneOS{}
	_ driver.ConfigReader   = StoneOS{}
	_ driver.LoginInspector = StoneOS{}
)

// role is the HA marker: M(aster), B(ackup), F(ault).
const role = `(?:\((?P<role>[MBF])\))?`

// Grammar is the StoneOS dialect.
func Grammar() terminal.Grammar {
	g := family.Grammar([]terminal.Prompt{
		{Mode: terminal.ModeConfigSub, Expr: terminal.Host + role + `\(config-[^)\r\n]+\)#`},
		{Mode: terminal.ModeConfig, Expr: terminal.Host + role + `\(config\)#`},
		{Mode: terminal.ModePrivileged, Expr: terminal.Host + role + `#`},
		{Mode: terminal.ModeUser, Expr: terminal.Host + role + `[>$]`},
	}, append(family.CaretErrors(),
		terminal.Sig(terminal.ReasonInvalidInput, `^\s*\^-+`),
		terminal.Sig(terminal.ReasonInvalidInput, `(?i)^\s*(?:Unknown|Invalid) command`),
		terminal.Sig(terminal.ReasonCommandFailed, `(?i)^\s*Error:`)))
	g.Config = terminal.ConfigMode{Enter: "configure", Leave: "end"}
	g.Preparation = []string{"terminal length 0"}
	return g
}

// New returns the StoneOS platform.
func New() StoneOS {
	return StoneOS{
		Base:       driver.NewBase("hillstone", Grammar()),
		ConfigRead: family.Read("show configuration running"),
		Verbs:      driver.Verbs{"show", "ping", "traceroute"},
		Matcher:    driver.Matcher{Vendor: regexp.MustCompile(`\bhillstone\b`)},
	}
}

// SaveProcedure saves every configuration and requires the completion
// message.
func (StoneOS) SaveProcedure() terminal.Procedure {
	return terminal.Procedure{
		Name: "save",
		Steps: []terminal.Command{{Text: "save all", Timeout: 5 * time.Minute, Rules: []terminal.Rule{
			{Name: "save_confirm", Pattern: `(?i)save (?:configuration|all)[^\r\n]*\[y\]/n\s*:?`, Reply: terminal.Answer("y")},
		}}},
		Success: []terminal.Signature{terminal.Sig("save_ok", `(?im)^\s*Saving configuration is finished\.?\s*$`)},
		Failure: family.SaveFailed(),
	}
}

var roleRe = regexp.MustCompile(`\(([MBF])\)(?:\([^)]*\))?[#>$]\s*$`)

// AfterLogin reads the HA role from the prompt; a backup or faulty member
// must not be changed.
func (StoneOS) AfterLogin(_, prompt string) (driver.LoginState, error) {
	st := driver.LoginState{Writable: true}
	if m := roleRe.FindStringSubmatch(prompt); m != nil {
		st.Role = map[string]string{"M": "master", "B": "backup", "F": "fault"}[m[1]]
		st.Writable = m[1] == "M"
	}
	return st, nil
}

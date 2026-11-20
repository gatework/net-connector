// Package centec implements the Centec CNOS platform.
package centec

import (
	"regexp"
	"time"

	"github.com/gatework/net-connector/driver"
	"github.com/gatework/net-connector/terminal"
	"github.com/gatework/net-connector/vendors/internal/family"
)

// CNOS is a Centec switch with an IOS-like CLI.
type CNOS struct {
	driver.Base
	family.ConfigRead
	driver.Verbs
	driver.Matcher
}

var (
	_ driver.Saver        = CNOS{}
	_ driver.ConfigReader = CNOS{}
)

// Grammar is the CNOS dialect.
func Grammar() terminal.Grammar {
	g := family.Grammar(family.IOS(), append(family.CaretErrors(),
		terminal.Sig(terminal.ReasonInvalidInput, `(?i)^\s*%\s*(?:Syntax error|Unknown|Error)\b`)))
	g.Privilege = family.Enable()
	g.Config = terminal.ConfigMode{Enter: "configure terminal", Leave: "end"}
	g.Preparation = []string{"terminal length 0"}
	return g
}

// New returns the CNOS platform.
func New() CNOS {
	return CNOS{
		Base:       driver.NewBase("centec", Grammar()),
		ConfigRead: family.Read("show running-config"),
		Verbs:      driver.Verbs{"show", "ping", "traceroute"},
		Matcher:    driver.Matcher{Vendor: regexp.MustCompile(`\bcentec\b`)},
	}
}

// SaveProcedure copies running to startup and requires "[OK]".
func (CNOS) SaveProcedure() terminal.Procedure {
	return terminal.Procedure{
		Name:    "save",
		Steps:   []terminal.Command{family.Command("copy running-config startup-config", 5*time.Minute)},
		Success: []terminal.Signature{terminal.Sig("save_ok", `(?im)^\s*(?:\[OK\]|Copy complete\.?)\s*$`)},
		Failure: family.SaveFailed(),
	}
}

// Package centec implements the Centec network device platform.
package centec

import (
	"time"

	"github.com/gatework/net-connector/vendors/internal/driver"
)

var saveConfirmationPattern = driver.Regex(`(?i)^(?:\[OK\]|Copy complete\.)$`)

// Platform is the built-in Centec platform.
type Platform struct {
	driver.Base
	driver.ReadOnlyCommands
	tftpPolicy
}

// New returns the built-in Centec platform.
func New() Platform {
	return Platform{Base: newBase(), ReadOnlyCommands: readOnly, tftpPolicy: newTFTPPolicy()}
}

func newBase() driver.Base {
	p := driver.BaseTerminal("centec")
	p.ConfigCommands = []string{"terminal length 0", "show running-config"}
	p.SaveCommands = []string{"copy running-config startup-config"}
	p.LoginPrompt = driver.Pattern(`(?:\A|[\r\n])\S+[>#]\s*\z`)
	p.CommandPrompt = p.LoginPrompt
	p.CommandErrors = driver.Regexps(`(?im)^[ \t]*%[ \t]+(?:Syntax\s+error|Invalid|Incomplete|Ambiguous|Unknown|Error)\b`)
	return driver.NewBase(p, 60*time.Second, configFactory(), saveConfirmationPattern)
}

// readOnly lists the commands this family accepts for read-only collection.
var readOnly = driver.ReadOnlyCommands{Verbs: []string{"show", "ping", "traceroute"}}

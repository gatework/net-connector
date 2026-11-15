// Package topsec implements the Topsec network device platform.
package topsec

import (
	"time"

	"github.com/gatework/net-connector/vendors/internal/driver"
)

// Platform is the built-in Topsec platform.
type Platform struct {
	driver.Base
	driver.ReadOnlyCommands
}

// New returns the built-in Topsec platform.
func New() Platform {
	return Platform{Base: newBase(), ReadOnlyCommands: readOnly}
}

func newBase() driver.Base {
	p := driver.BaseTerminal("topsec")
	p.ConfigCommands = []string{"show-running nostop"}
	p.LoginPrompt = driver.Pattern(`(?:\A|[\r\n])[^\s#>]*#\s*\z`)
	p.CommandPrompt = driver.Pattern(`(?:\A|[\r\n])[^\s#>]*#\s*\z`)
	p.CommandErrors = driver.Regexps(`(?im)^[ \t]*(?:%[ \t]*)?(?:Unknown|Invalid|Incomplete|Ambiguous)\s+command\b`, `(?im)^[ \t]*(?:Error:|Permission denied\b)`)
	return driver.NewBase(p, 120*time.Second, driver.BaseConfigFactory(), nil)
}

// readOnly lists the commands this family accepts for read-only collection.
var readOnly = driver.ReadOnlyCommands{Verbs: []string{"show", "show-running"}}

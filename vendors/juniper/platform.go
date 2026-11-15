// Package juniper implements the Juniper Junos network device platform.
package juniper

import (
	"time"

	"github.com/gatework/net-connector/vendors/internal/driver"
)

// Platform is the built-in Juniper Junos platform. Description writes stay
// unavailable because the platform lacks an isolated candidate.
type Platform struct {
	driver.Base
	driver.ReadOnlyCommands
	driver.FactsReader
	driver.TopologyReader
	driver.WriteRestriction
	remoteBackupPolicy
}

// New returns the built-in Juniper Junos platform.
func New() Platform {
	return Platform{
		Base:               newBase(),
		ReadOnlyCommands:   readOnly,
		FactsReader:        driver.FactsReader{Commands: []string{"show version | no-more", "show chassis hardware | no-more"}, Template: "juniper/show_version.textfsm"},
		TopologyReader:     driver.NewTopologyReader("show lldp neighbors detail | no-more", topologyParser()),
		WriteRestriction:   driver.WriteRestriction{Code: "candidate_isolation_unavailable"},
		remoteBackupPolicy: remoteBackupPolicy{},
	}
}

func newBase() driver.Base {
	p := driver.BaseTerminal("juniper")
	p.ConfigCommands = []string{"show configuration | display set | no-more"}
	p.LoginPrompt = driver.Pattern(`(?:\A|[\r\n])[^\s@]+@[^\s>#]+>[ \t]*\z`)
	p.CommandPrompt = p.LoginPrompt
	p.Pager = driver.Pattern(`(?i)(?:\A|[\r\n])[ \t]*---\(more(?: \d+%)?\)---[ \t]*\z`)
	p.CommandErrors = driver.Regexps(`(?im)^[ \t]*(?:error:|syntax error[,.]|unknown command\b|permission denied\b|(?:ftp|scp|ssh):\s)`)
	return driver.NewBase(p, 120*time.Second, driver.BaseConfigFactory(), nil)
}

// readOnly lists the commands this family accepts for read-only collection.
var readOnly = driver.ReadOnlyCommands{Verbs: []string{"show", "ping", "traceroute"}}

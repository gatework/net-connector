// Package paloalto implements the Palo Alto Networks PAN-OS device platform.
package paloalto

import (
	"time"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/vendors/internal/driver"
)

// Platform is the built-in Palo Alto Networks platform. Description writes stay
// unavailable because the platform lacks an isolated candidate.
type Platform struct {
	driver.Base
	driver.ReadOnlyCommands
	driver.TopologyReader
	driver.WriteRestriction
	tftpPolicy
}

// New returns the built-in Palo Alto Networks platform.
func New() Platform {
	return Platform{
		Base:             newBase(),
		ReadOnlyCommands: readOnly,
		TopologyReader:   driver.NewTopologyReader("show lldp neighbors all", topologyParser()),
		WriteRestriction: driver.WriteRestriction{Code: "candidate_isolation_unavailable"},
		tftpPolicy:       newTFTPPolicy(),
	}
}

func newBase() driver.Base {
	p := driver.BaseTerminal("palo_alto")
	p.ConfigCommands = []string{"set cli pager off", "set cli config-output-format set", "show config diff", "configure", "show", "exit", "show config diff"}
	p.LoginPrompt = driver.Pattern(`(?:\A|[\r\n])[^\s@]+@[^\s>#]+[>#]\s*\z`)
	p.CommandPrompt = p.LoginPrompt
	p.CommandErrors = driver.Regexps(`(?im)^[ \t]*(?:Invalid syntax|Unknown command|Server error|Command failed)(?:[.:]|\s)`)
	p.LoginInteractions = []connector.Interaction{driver.LoginInteraction(`(?i)(?:acknowledge|accept)[\s\S]*(?:yes/no|\[y/n\]|enter\s+yes)[^\r\n]*\z`, "yes\n")}
	return driver.NewBase(p, 120*time.Second, configFactory(), nil)
}

// readOnly lists the commands this family accepts for read-only collection.
var readOnly = driver.ReadOnlyCommands{Verbs: []string{"show", "ping", "traceroute"}}

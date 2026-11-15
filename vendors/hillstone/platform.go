// Package hillstone implements the Hillstone network device platform.
package hillstone

import (
	"time"

	"github.com/gatework/net-connector/topology"
	"github.com/gatework/net-connector/vendors/internal/driver"
)

var saveConfirmationPattern = driver.Regex(`(?i)^Saving configuration is finished\.?$`)

// Platform is the built-in Hillstone platform.
type Platform struct {
	driver.Base
	driver.ReadOnlyCommands
	driver.TopologyReader
	driver.DescriptionWriter
	tftpPolicy
}

// New returns the built-in Hillstone platform.
func New() Platform {
	return Platform{
		Base:              newBase(),
		ReadOnlyCommands:  readOnly,
		TopologyReader:    driver.NewTopologyReader("show lldp neighbor-information", topologyParser()),
		DescriptionWriter: driver.NewDescriptionWriter(topology.WriteMode{Enter: "configure", Leave: "exit", InterfaceExit: "exit"}),
		tftpPolicy:        newTFTPPolicy(),
	}
}

func newBase() driver.Base {
	p := driver.BaseTerminal("hillstone")
	p.ConfigCommands = []string{"terminal length 0", "show configuration running"}
	p.SaveCommands = []string{"save all"}
	p.LoginPrompt = driver.Pattern(`(?:\A|[\r\n])\S+(?:[#>$]|\([MBF]\))\s*\z`)
	p.CommandPrompt = driver.Pattern(`(?:\A|[\r\n])\S+(?:#|\([MBF]\))\s*\z`)
	p.Pager = driver.Pattern(`(?i)(?:\A|[\r\n])[ \t]*--More--[ \t\x00\x08]*(?:\r|\n|\z)`)
	p.CommandErrors = driver.Regexps(`(?im)^[ \t]*\^-+`, `(?m)^\s*\^`, `(?im)^[ \t]*(?:Unknown|Invalid|Error)\s+command`, `(?im)^[ \t]*Error:\s*[^\r\n]+`)
	return driver.NewBase(p, 60*time.Second, configFactory(), saveConfirmationPattern)
}

// readOnly lists the commands this family accepts for read-only collection.
var readOnly = driver.ReadOnlyCommands{Verbs: []string{"show", "ping", "traceroute"}}

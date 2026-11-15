// Package huawei implements the Huawei VRP network device platform.
package huawei

import (
	"time"

	"github.com/gatework/net-connector/vendors/internal/driver"
)

var saveConfirmationPattern = driver.Regex(`(?i)^(?:Info:[ \t]*)?(?:Save the configuration successfully\.|The configuration has been saved successfully\.|Configuration is saved to device successfully\.)$`)

// Platform is the built-in Huawei VRP platform.
type Platform struct {
	driver.Base
	driver.ReadOnlyCommands
	driver.FactsReader
	driver.TopologyReader
	tftpPolicy
}

// New returns the built-in Huawei VRP platform.
func New() Platform {
	return Platform{
		Base:             newBase(),
		ReadOnlyCommands: readOnly,
		FactsReader:      driver.FactsReader{Commands: []string{"display version", "display esn"}, Template: "huawei/display_version.textfsm"},
		TopologyReader:   driver.NewTopologyReader("display lldp neighbor brief", topologyParser()),
		tftpPolicy:       newTFTPPolicy(),
	}
}

func newBase() driver.Base {
	p := driver.BaseTerminal("huawei")
	p.ConfigCommands = []string{"dis cur"}
	p.SaveCommands = []string{"save force"}
	p.UsernamePrompt = driver.Pattern(`(?i)(?:login|Username):\s*\z`)
	p.LoginPrompt = driver.Pattern(`(?:\A|[\r\n])\s*\S+[>\]]\s*\z`)
	p.CommandPrompt = driver.Pattern(`(?:\A|[\r\n])[^\r\n]+[>\]]\s*\z`)
	p.CommandErrors = driver.PositionMarkerCommandErrors()
	p.Interactions = driver.YesNoConfirmations()
	p.PrivilegeCommand = "su"
	p.PrivilegedPrompt = driver.Regex(`\]\s*\z`)
	p.PrivilegePrompt = driver.Pattern(`(?is)privilege\s+(?:level\s+is|is\s+).+>\s*\z`)
	return driver.NewBase(p, 10*time.Second, driver.BaseConfigFactory(), saveConfirmationPattern)
}

// readOnly lists the commands this family accepts for read-only collection.
var readOnly = driver.ReadOnlyCommands{Verbs: []string{"display", "dis", "ping", "tracert"}}

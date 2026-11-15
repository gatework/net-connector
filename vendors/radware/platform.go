// Package radware implements the Radware ADC network device platform.
package radware

import (
	"context"
	"time"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/vendors/internal/driver"
)

var haStatePattern = driver.Regex(`(?im)^\s*HA\s+State:\s*(\S+)`)

// Platform is the built-in Radware ADC platform. It reads interface
// descriptions but does not discover neighbors.
type Platform struct {
	driver.Base
	driver.ReadOnlyCommands
	driver.DescriptionReader
	driver.InterfaceIdentityPolicy
	tftpPolicy
}

// New returns the built-in Radware ADC platform.
func New() Platform {
	parser := topologyParser()
	return Platform{
		Base:                    newBase(),
		ReadOnlyCommands:        readOnly,
		DescriptionReader:       driver.DescriptionReader{Parser: parser},
		InterfaceIdentityPolicy: driver.InterfaceIdentityPolicy{Parser: parser},
		tftpPolicy:              newTFTPPolicy(),
	}
}

func newBase() driver.Base {
	p := driver.BaseTerminal("radware")
	p.LoginInteractions = []connector.Interaction{driver.LoginInteraction(`(?i)Confirm\s+seeing\s+above\s+note\s+\[y\]:\s*\z`, "y\n")}
	p.ConfigCommands = []string{"/cfg/dump"}
	p.SaveCommands = []string{"/cfg/save"}
	p.LoginPrompt = driver.Pattern(`(?:\A|[\r\n])(?:>>[^\r\n]*#|[^>\r\n][^\r\n]*[>#]|>[^>\r\n][^\r\n]*[>#])\s*\z`)
	p.CommandPrompt = driver.Pattern(`(?:\A|[\r\n])[^\r\n]+#\s*\z`)
	p.CommandErrors = driver.Regexps(`(?im)^[ \t]*(?:Unknown|Invalid|Error)\s+command\b`)
	p.Interactions = []connector.Interaction{driver.Interaction(`(?i)Confirm\s+Sync\s+to\s+Peer\s+\[y/n\]:\s*\z`, "y\n"), driver.Interaction(`(?i)Synchronize\s+configuration\s+changes\?\s+\[y/n\]:\s*\z`, "y\n"), driver.Interaction(`(?i)Confirm\s+saving\s+to\s+FLASH\s+\[y/n\]:\s*\z`, "y\n"), driver.Interaction(`(?i)Confirm\s+operation\s+without\s+applying\s+changes\s+\(leave\s+them\s+pending\)\s+\[y/n\]:\s*\z`, "y\n"), driver.Interaction(`(?i)Confirm\s+operation\s+without\s+saving\s+changes\s+\(leave\s+them\s+pending\)\s+\[y/n\]:?\s*\z`, "y\n"), driver.Interaction(`(?i)Confirm\s+seeing\s+above\s+note\s+\[y\]:\s*\z`, "y\n"), driver.Interaction(`(?i)Please\s+enter\s+y\s+to\s+perform\s+the\s+action,\s+n\s+to\s+skip\s+it:\s*\z`, "y\n"), driver.Interaction(`(?i)Display\s+private\s+keys\?\s+\[y/n\]:\s*\z`, "n\n")}
	return driver.NewBase(p, 30*time.Second, configFactory(), nil)
}

// AfterLogin reads the high-availability role from the login banner.
func (Platform) AfterLogin(_ context.Context, step connector.StepResult) (connector.LoginState, error) {
	match := haStatePattern.FindStringSubmatch(step.Response().Raw())
	if len(match) > 1 {
		return connector.LoginState{Labels: map[string]string{"ha_state": match[1]}}, nil
	}
	return connector.LoginState{}, nil
}

// readOnly lists the commands this family accepts for read-only collection.
var readOnly = driver.ReadOnlyCommands{PathPrefixes: []string{"/info", "/stats"}, Verbs: []string{"/cfg/dump"}}

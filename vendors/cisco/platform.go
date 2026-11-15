// Package cisco implements Cisco IOS and NX-OS network device platforms.
package cisco

import (
	"time"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/topology"
	"github.com/gatework/net-connector/vendors/internal/driver"
)

// IOSPlatform is the built-in Cisco IOS platform.
type IOSPlatform struct {
	driver.Base
	driver.ReadOnlyCommands
	driver.FactsReader
	driver.TopologyReader
	driver.DescriptionWriter
	iosTFTPPolicy
}

// NXOSPlatform is the built-in Cisco NX-OS platform.
type NXOSPlatform struct {
	driver.Base
	driver.ReadOnlyCommands
	driver.FactsReader
	driver.TopologyReader
	driver.DescriptionWriter
	nxosTFTPPolicy
}

const neighborCommand = "show cdp neighbors detail"

var writeMode = topology.WriteMode{Enter: "configure terminal", Leave: "end", InterfaceExit: "exit"}

// IOS returns the built-in Cisco IOS platform.
func IOS() IOSPlatform {
	return IOSPlatform{
		Base:              newIOSBase(),
		ReadOnlyCommands:  readOnly,
		FactsReader:       driver.FactsReader{Commands: []string{"show version"}, Template: "cisco/show_version.textfsm"},
		TopologyReader:    driver.NewTopologyReader(neighborCommand, iosTopologyParser()),
		DescriptionWriter: driver.NewDescriptionWriter(writeMode),
		iosTFTPPolicy:     newIOSTFTPPolicy(),
	}
}

// NXOS returns the built-in Cisco NX-OS platform.
func NXOS() NXOSPlatform {
	return NXOSPlatform{
		Base:              newNXOSBase(),
		ReadOnlyCommands:  readOnly,
		FactsReader:       driver.FactsReader{Commands: []string{"show version"}, Template: "cisco_nxos/show_version.textfsm"},
		TopologyReader:    driver.NewTopologyReader(neighborCommand, nxosTopologyParser()),
		DescriptionWriter: driver.NewDescriptionWriter(writeMode),
		nxosTFTPPolicy:    newNXOSTFTPPolicy(),
	}
}

var saveConfirmationPattern = driver.Regex(`(?i)^(?:\[OK\]|Copy complete\.)$`)

func newIOSBase() driver.Base {
	p := driver.BaseTerminal("cisco_ios")
	p.ConfigCommands = []string{"terminal length 0", "show running-config"}
	p.SaveCommands = []string{"copy running-config startup-config"}
	p.LoginPrompt = driver.Pattern(`(?:\A|[\r\n])\S+[>#]\s*\z`)
	p.CommandPrompt = p.LoginPrompt
	p.Pager = driver.Pattern(`(?i)(?:\A|[\r\n])[^\S\r\n]*--More--[^\r\n]*(?:\r|\n|\z)`)
	p.CommandErrors = driver.Regexps(`(?im)^[ \t]*%[ \t]+(?:Invalid|Incomplete|Ambiguous)\s+(?:input|command)\b`, `(?m)^[ \t]*\^`)
	p.Interactions = []connector.Interaction{driver.Interaction(`(?i)Destination\s+filename\s+\[[^\]]+\]\?\s*\z`, "\n"), driver.Interaction(`(?i)Do\s+you\s+want\s+to\s+overwrite\?\s*\[yes/no\]\s*\z`, "yes\n"), driver.Interaction(`(?i)Proceed\s+with\s+copy\?\s*\[confirm\]\s*\z`, "\n")}
	return driver.NewBase(p, 60*time.Second, configFactory(), saveConfirmationPattern)
}

func newNXOSBase() driver.Base {
	p := driver.BaseTerminal("cisco_nxos")
	p.ConfigCommands = []string{"terminal length 0", "show running-config"}
	p.SaveCommands = []string{"copy run start"}
	p.LoginPrompt = driver.Pattern(`\S+[>#]\s*\z`)
	p.CommandPrompt = p.LoginPrompt
	p.Pager = driver.Pattern(`(?i)(?:\A|[\r\n])[ \t]*(?:\x1b\[[0-9;]*[A-Za-z])*--More--(?:[ \t\x00\x08]|\x1b\[[0-9;]*[A-Za-z])*(?:\r|\n|\z)`)
	p.CommandErrors = driver.Regexps(`(?im)^[ \t]*%?[ \t]*(?:(?:Invalid|Ambiguous|Incomplete)\s+command(?:\s+\([^)]+\))?|Invalid\s+parameter\s+detected)\s+at\s+'\^'\s+marker\.`, `(?m)^[ \t]*\^`, `(?im)^[ \t]*%[ \t]+(?:Invalid|Ambiguous|Incomplete)\s+command\b`, `(?im)^[ \t]*%?[ \t]*Invalid\s+parameter\s+detected\b`, `(?im)^[ \t]*syntax\s+error\b`)
	p.Interactions = []connector.Interaction{driver.Interaction(`(?i)Destination\s+filename\s+\[[^\]]+\]\?\s*\z`, "\n"), driver.Interaction(`(?i)Do\s+you\s+want\s+to\s+overwrite\?\s*\[yes/no\]\s*\z`, "yes\n")}
	return driver.NewBase(p, 60*time.Second, configFactory(), saveConfirmationPattern)
}

// readOnly lists the commands this family accepts for read-only collection.
var readOnly = driver.ReadOnlyCommands{Verbs: []string{"show", "dir", "ping", "traceroute"}}

// Package cisco implements the Cisco IOS/IOS-XE ("cisco_ios") and NX-OS
// ("cisco_nxos") platforms.
package cisco

import (
	"regexp"
	"strings"
	"time"

	"github.com/gatework/net-connector/driver"
	"github.com/gatework/net-connector/terminal"
	"github.com/gatework/net-connector/vendors/internal/family"
)

// IOS is an IOS or IOS-XE device.
type IOS struct {
	driver.Base
	family.ConfigRead
	driver.Verbs
	driver.Matcher
}

// NXOS is an NX-OS switch.
type NXOS struct {
	driver.Base
	family.ConfigRead
	driver.Verbs
	driver.Matcher
}

var (
	_ driver.Saver        = IOS{}
	_ driver.ConfigReader = IOS{}
	_ driver.Exporter     = IOS{}
	_ driver.Saver        = NXOS{}
	_ driver.Checkpointer = NXOS{}
	_ driver.Exporter     = NXOS{}
)

var cisco = regexp.MustCompile(`\bcisco\b`)

func grammar() terminal.Grammar {
	g := family.Grammar(family.IOS(), family.CaretErrors())
	g.Privilege = family.Enable()
	g.Config = terminal.ConfigMode{Enter: "configure terminal", Leave: "end"}
	g.Preparation = []string{"terminal length 0", "terminal width 511"}
	g.Rules = []terminal.Rule{
		{Name: "destination_filename", Pattern: `(?i)Destination filename \[[^\]]*\]\?`, Reply: terminal.Enter()},
		{Name: "proceed_with_copy", Pattern: `(?i)Proceed with copy\? \[confirm\]`, Reply: terminal.Enter()},
		{Name: "overwrite", Pattern: `(?i)Do you want to overwrite\? \[yes/no\]`, Reply: terminal.Answer("yes")},
		{Name: "confirm", Pattern: `(?i)\[confirm\]`, Reply: terminal.Enter(), Risk: terminal.RiskDisruptive},
	}
	return g
}

// NewIOS returns the IOS platform.
func NewIOS() IOS {
	return IOS{
		Base:       driver.NewBase("cisco_ios", grammar()),
		ConfigRead: family.Read("show running-config", preamble...),
		Verbs:      driver.Verbs{"show", "dir", "ping", "traceroute"},
		Matcher:    driver.Matcher{Vendor: cisco, OS: regexp.MustCompile(`\bios\b|\bios\s*xe\b`)},
	}
}

// NewNXOS returns the NX-OS platform.
func NewNXOS() NXOS {
	g := grammar()
	g.Errors = append(g.Errors, terminal.Sig(terminal.ReasonInvalidInput, `(?i)^\s*%?\s*(?:Invalid|Ambiguous|Incomplete) command(?: \([^)]*\))? at '\^' marker`),
		terminal.Sig(terminal.ReasonInvalidInput, `(?i)^\s*syntax error`))
	return NXOS{
		Base:       driver.NewBase("cisco_nxos", g),
		ConfigRead: family.Read("show running-config", preamble...),
		Verbs:      driver.Verbs{"show", "dir", "ping", "traceroute"},
		Matcher: driver.Matcher{Any: []driver.Matcher{
			{Vendor: cisco, OS: regexp.MustCompile(`nx\s*os|nexus`)},
			{Vendor: cisco, Model: regexp.MustCompile(`\bnexus\b|\bn\s*[3579]k\b`)},
		}},
	}
}

var preamble = []*regexp.Regexp{
	regexp.MustCompile(`^Building configuration`),
	regexp.MustCompile(`^Current configuration\s*:`),
	regexp.MustCompile(`^!Command: show running-config`),
	regexp.MustCompile(`^!(?:Running configuration last done at|Time):`),
}

func save() terminal.Procedure {
	return terminal.Procedure{
		Name:    "save",
		Steps:   []terminal.Command{family.Command("copy running-config startup-config", 5*time.Minute)},
		Success: []terminal.Signature{terminal.Sig("save_ok", `(?im)^\s*(?:\[OK\]|Copy complete\.?)\s*$`)},
		Failure: family.SaveFailed(),
	}
}

// SaveProcedure copies running to startup and requires "[OK]".
func (IOS) SaveProcedure() terminal.Procedure { return save() }

// SaveProcedure copies running to startup and requires "Copy complete".
func (NXOS) SaveProcedure() terminal.Procedure { return save() }

// ExportProcedure answers the interactive "copy running-config tftp:".
func (IOS) ExportProcedure(e driver.Export) (terminal.Procedure, error) {
	if e.Protocol != "" && e.Protocol != "tftp" {
		return terminal.Procedure{}, driver.ErrUnsupported
	}
	if err := family.ValidateExport(e.Server, e.File); err != nil {
		return terminal.Procedure{}, err
	}
	cmd := terminal.Command{Text: "copy running-config tftp:", Timeout: max(e.Timeout, 3*time.Minute), Rules: []terminal.Rule{
		{Name: "remote_host", Pattern: `(?i)Address or name of remote host \[[^\]]*\]\?`, Reply: terminal.Answer(e.Server)},
		{Name: "destination_filename", Pattern: `(?i)Destination filename \[[^\]]*\]\?`, Reply: terminal.Answer(e.File)},
	}}
	return terminal.Procedure{
		Name: "export", Steps: []terminal.Command{cmd},
		Success: append(family.FileSent(), terminal.Sig("file_sent", `(?im)^\s*\[OK - (?P<bytes>\d+) bytes\]\s*$`)),
		Failure: family.FileFailed(),
	}, nil
}

// ExportProcedure copies the running configuration to a TFTP URL in the
// management VRF unless another is given.
func (NXOS) ExportProcedure(e driver.Export) (terminal.Procedure, error) {
	if e.Protocol != "" && e.Protocol != "tftp" {
		return terminal.Procedure{}, driver.ErrUnsupported
	}
	vrf := e.VRF
	if vrf == "" {
		vrf = "management"
	}
	if err := family.ValidateExport(e.Server, e.File, vrf); err != nil {
		return terminal.Procedure{}, err
	}
	cmd := "copy running-config tftp://" + e.Server + "/" + strings.TrimPrefix(e.File, "/") + " vrf " + vrf
	return terminal.Procedure{
		Name:  "export",
		Steps: []terminal.Command{{Text: cmd, Timeout: max(e.Timeout, 3*time.Minute)}},
		Success: append(family.FileSent(),
			terminal.Sig("file_sent", `(?im)^\s*TFTP put operation was successful`),
			terminal.Sig("file_sent", `(?im)^\s*Copy complete\.?\s*$`)),
		Failure: family.FileFailed(),
	}, nil
}

// CheckpointProcedure records a named checkpoint. The confirmation follows
// the fabric NX-OS evidence: "Done".
func (NXOS) CheckpointProcedure(name string) (terminal.Procedure, error) {
	if !family.Token(name) {
		return terminal.Procedure{}, driver.ErrUnsupported
	}
	return terminal.Procedure{
		Name:    "checkpoint",
		Steps:   []terminal.Command{family.Command("checkpoint "+name, 5*time.Minute)},
		Success: []terminal.Signature{terminal.Sig("checkpoint_ok", `(?im)(?:^|\.)\s*Done\.?\s*$|\bsuccess(?:ful(?:ly)?)?\b`)},
		Failure: []terminal.Signature{terminal.Sig("checkpoint_failed", `(?im)^\s*(?:ERROR:|Error:|Checkpoint (?:creation )?failed|.*\balready exists\b)`)},
	}, nil
}

// RollbackProcedure restores a checkpoint atomically: every difference
// applies or none does.
func (NXOS) RollbackProcedure(name string) (terminal.Procedure, error) {
	if !family.Token(name) {
		return terminal.Procedure{}, driver.ErrUnsupported
	}
	return terminal.Procedure{
		Name:    "rollback",
		Steps:   []terminal.Command{{Text: "rollback running-config checkpoint " + name + " atomic", Timeout: 10 * time.Minute, Allow: terminal.RiskDisruptive}},
		Success: []terminal.Signature{terminal.Sig("rollback_ok", `(?im)^\s*Rollback completed successfully\.?\s*$`)},
		// Line-anchored: NX-OS prints notes such as "Applying config
		// parallelly may fail Rollback verification" on success.
		Failure: []terminal.Signature{terminal.Sig("rollback_failed", `(?im)^\s*(?:ERROR:|Error:|Rollback failed)`)},
	}, nil
}

// Package huawei implements the Huawei VRP platform.
package huawei

import (
	"regexp"
	"time"

	"github.com/gatework/net-connector/driver"
	"github.com/gatework/net-connector/terminal"
	"github.com/gatework/net-connector/vendors/internal/family"
)

// VRP is a Huawei VRP switch or router.
type VRP struct {
	driver.Base
	family.ConfigRead
	driver.Verbs
	driver.Matcher
}

var (
	_ driver.Saver        = VRP{}
	_ driver.ConfigReader = VRP{}
	_ driver.Exporter     = VRP{}
)

// Grammar is the VRP dialect: Comware-style prompts, with "~" and "*"
// marking uncommitted changes on two-stage-commit releases.
func Grammar() terminal.Grammar {
	g := family.Grammar(family.Comware(), append(family.CaretErrors(), family.ErrorLines()...))
	g.Config = terminal.ConfigMode{Enter: "system-view", Leave: "return"}
	g.Preparation = []string{"screen-length 0 temporary"}
	g.Rules = []terminal.Rule{
		{Name: "save_continue", Pattern: `(?i)Are you sure to continue\?\s*\[Y/N\]\s*:?`, Reply: terminal.Answer("Y"), Risk: terminal.RiskDisruptive},
		{Name: "default_cfg_name", Pattern: `(?i)Please input the file name\s*\(\*\.cfg, \*\.zip\)\s*\[[^\]]+\]\s*:?`, Reply: terminal.Enter()},
	}
	return g
}

// New returns the VRP platform.
func New() VRP {
	return VRP{
		Base:       driver.NewBase("huawei", Grammar()),
		ConfigRead: family.Read("display current-configuration"),
		Verbs:      driver.Verbs{"display", "dis", "ping", "tracert"},
		Matcher:    driver.Matcher{Vendor: regexp.MustCompile(`\bhuawei\b`)},
	}
}

// SaveProcedure saves the configuration. "save" asks to continue; the
// procedure answers it, nothing else.
func (VRP) SaveProcedure() terminal.Procedure {
	return terminal.Procedure{
		Name: "save",
		Steps: []terminal.Command{{Text: "save", Timeout: 5 * time.Minute, Rules: []terminal.Rule{
			{Name: "save_continue", Pattern: `(?i)Are you sure to continue\?\s*\[Y/N\]\s*:?`, Reply: terminal.Answer("Y")},
		}}},
		Success: []terminal.Signature{terminal.Sig("save_ok",
			`(?im)^\s*(?:Info:\s*)?(?:Save the configuration successfully|The configuration has been saved successfully|Configuration is saved to device successfully)\.?\s*$`)},
		Failure: family.SaveFailed(),
	}
}

// ExportProcedure uploads a device file with "tftp <server> put".
func (VRP) ExportProcedure(e driver.Export) (terminal.Procedure, error) {
	if e.Protocol != "" && e.Protocol != "tftp" {
		return terminal.Procedure{}, driver.ErrUnsupported
	}
	src := e.Source
	if src == "" {
		src = "vrpcfg.zip"
	}
	if err := family.ValidateExport(e.Server, e.File, src, e.VRF); err != nil {
		return terminal.Procedure{}, err
	}
	cmd := "tftp " + e.Server
	if e.VRF != "" {
		cmd += " vpn-instance " + e.VRF
	}
	cmd += " put " + src + " " + e.File
	return terminal.Procedure{
		Name:    "export",
		Steps:   []terminal.Command{{Text: cmd, Timeout: max(e.Timeout, 3*time.Minute)}},
		Success: family.FileSent(),
		Failure: family.FileFailed(),
	}, nil
}

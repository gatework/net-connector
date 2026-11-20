// Package h3c implements the H3C Comware platforms: switches and routers
// ("h3c") and wireless controllers ("h3c_wireless").
package h3c

import (
	"regexp"
	"time"

	"github.com/gatework/net-connector/driver"
	"github.com/gatework/net-connector/terminal"
	"github.com/gatework/net-connector/vendors/internal/family"
)

// Switch is a Comware switch or router.
type Switch struct {
	driver.Base
	family.ConfigRead
	driver.Verbs
	driver.Matcher
}

// Wireless is a Comware wireless controller. It shares the Comware dialect
// and differs in its key and inventory match.
type Wireless struct{ Switch }

var (
	_ driver.Saver        = Switch{}
	_ driver.ConfigReader = Switch{}
	_ driver.Exporter     = Switch{}
	_ driver.Classifier   = Wireless{}
)

// Grammar is the Comware dialect.
func Grammar() terminal.Grammar {
	g := family.Grammar(family.Comware(), append(family.CaretErrors(), family.ErrorLines()...))
	g.Config = terminal.ConfigMode{Enter: "system-view", Leave: "return"}
	g.Preparation = []string{"screen-length disable"}
	g.Rules = []terminal.Rule{
		{Name: "default_cfg_name", Pattern: `(?i)Please input the file name\(\*\.cfg\)\[[^\]]+\]\s*:?`, Reply: terminal.Enter()},
		{Name: "keep_file_name", Pattern: `(?i)\(To leave the existing filename unchanged, press the enter key\)\s*:?`, Reply: terminal.Enter()},
		{Name: "overwrite_startup", Pattern: `(?i)\S+\.cfg exists?, overwrite\?\s*\[Y/N\]\s*:?`, Reply: terminal.Answer("Y")},
		// Generic confirmations guard reboot, reset and delete: answered
		// only for commands that allow disruption.
		{Name: "confirm", Pattern: `(?i)(?:Are you sure|Continue)\??\s*\[Y/N\]\s*:?`, Reply: terminal.Answer("Y"), Risk: terminal.RiskDisruptive},
	}
	return g
}

var identity = driver.Matcher{Any: []driver.Matcher{
	{Vendor: regexp.MustCompile(`\bh3c\b`)},
	{OS: regexp.MustCompile(`^comware$`), Model: regexp.MustCompile(`^h3c\s+\S`)},
}}

// New returns the Comware switch platform.
func New() Switch { return newSwitch("h3c", identity) }

// NewWireless returns the Comware wireless controller platform.
func NewWireless() Wireless {
	m := driver.Matcher{Any: []driver.Matcher{
		{Vendor: regexp.MustCompile(`\bh3c\b`), OS: regexp.MustCompile(`wireless|wlan`)},
		{Vendor: regexp.MustCompile(`\bh3c\b`), Model: regexp.MustCompile(`^(?:h3c\s+)?(?:wx|ac)\s*\d`)},
		{OS: regexp.MustCompile(`^comware$`), Model: regexp.MustCompile(`^h3c\s+(?:wx|ac)\s*\d`)},
	}}
	return Wireless{newSwitch("h3c_wireless", m)}
}

func newSwitch(key string, m driver.Matcher) Switch {
	return Switch{Base: driver.NewBase(key, Grammar()), ConfigRead: family.Read("display current-configuration"), Verbs: driver.Verbs{"display", "dis", "ping", "tracert"}, Matcher: m}
}

// SaveProcedure saves without prompting ("save force") and requires the
// device to report success.
func (Switch) SaveProcedure() terminal.Procedure {
	return terminal.Procedure{
		Name:  "save",
		Steps: []terminal.Command{family.Command("save force", 5*time.Minute)},
		Success: []terminal.Signature{terminal.Sig("save_ok",
			`(?im)^\s*(?:Info:\s*)?(?:Saved the current configuration to mainboard device successfully|Configuration is saved to (?:mainboard )?device successfully)\.?\s*$`)},
		Failure: family.SaveFailed(),
	}
}

// ExportProcedure uploads a device file (normally the startup
// configuration, see StartupFile) with "tftp <server> put <source> <file>".
func (Switch) ExportProcedure(e driver.Export) (terminal.Procedure, error) {
	if e.Protocol != "" && e.Protocol != "tftp" {
		return terminal.Procedure{}, driver.ErrUnsupported
	}
	src := e.Source
	if src == "" {
		src = "startup.cfg"
	}
	if err := family.ValidateExport(e.Server, e.File, src, e.VRF); err != nil {
		return terminal.Procedure{}, err
	}
	cmd := "tftp " + e.Server + " put " + src + " " + e.File
	if e.VRF != "" {
		cmd += " vpn-instance " + e.VRF
	}
	return terminal.Procedure{
		Name:    "export",
		Steps:   []terminal.Command{{Text: cmd, Timeout: max(e.Timeout, 3*time.Minute)}},
		Success: family.FileSent(),
		Failure: family.FileFailed(),
	}, nil
}

var startupNext = regexp.MustCompile(`(?mi)^\s*Next main startup saved-configuration file:\s*(\S+)`)
var startupCurrent = regexp.MustCompile(`(?mi)^\s*Current startup saved-configuration file:\s*(\S+)`)

// StartupFile returns the startup configuration file named by the output
// of "display startup", preferring the next startup file.
func StartupFile(displayStartup string) (string, bool) {
	for _, re := range []*regexp.Regexp{startupNext, startupCurrent} {
		if m := re.FindStringSubmatch(displayStartup); m != nil && m[1] != "NULL" {
			return m[1], true
		}
	}
	return "", false
}

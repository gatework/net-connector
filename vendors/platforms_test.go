package vendors

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/topology"
	"github.com/gatework/net-connector/transfer"
)

func TestPlatformsAndDeclaredBehaviors(t *testing.T) {
	cases := []struct {
		name               string
		config, save       []string
		seconds            int
		prompt, diagnostic string
	}{
		{"h3c", []string{"dis cur"}, []string{"save force"}, 60, "<core>", "% Unrecognized command found at '^' position."},
		{"h3c_wireless", []string{"dis cur"}, []string{"save force"}, 60, "[AC]", "Error: invalid"},
		{"cisco_ios", []string{"terminal length 0", "show running-config"}, []string{"copy running-config startup-config"}, 60, "router#", "% Invalid input detected"},
		{"cisco_nxos", []string{"terminal length 0", "show running-config"}, []string{"copy run start"}, 60, "nexus#", "Invalid parameter detected at '^' marker."},
		{"huawei", []string{"dis cur"}, []string{"save force"}, 10, "<Huawei>", "Permission denied."},
		{"hillstone", []string{"terminal length 0", "show configuration running"}, []string{"save all"}, 60, "stone(M)", "Error: no such object"},
		{"radware", []string{"/cfg/dump"}, []string{"/cfg/save"}, 30, ">> Standalone ADC - Main#", "Unknown command"},
		{"palo_alto", []string{"set cli pager off", "set cli config-output-format set", "show config diff", "configure", "show", "exit", "show config diff"}, nil, 120, "admin@fw>", "Invalid syntax."},
		{"topsec", []string{"show-running nostop"}, nil, 120, "TopsecOS#", "% Incomplete command"},
		{"fortinet", []string{"show full-configuration"}, []string{"execute cfg save"}, 120, "FGT-100F (root) # ", "Command fail. Return code -61"},
		{"juniper", []string{"show configuration | display set | no-more"}, nil, 120, "audit@ex01> ", "scp: permission denied"},
		{"centec", []string{"terminal length 0", "show running-config"}, []string{"copy running-config startup-config"}, 60, "Switch#", "% Syntax error"},
	}
	if len(NewBuiltinRegistry().Names()) != len(cases) {
		t.Fatalf("names: %v", NewBuiltinRegistry().Names())
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			p := lookupPlatform(t, c.name)
			if !reflect.DeepEqual(p.Terminal().ConfigCommands, c.config) || !reflect.DeepEqual(p.Terminal().SaveCommands, c.save) || p.Terminal().CommandTimeout != time.Duration(c.seconds)*time.Second {
				t.Fatalf("profile: %#v", p)
			}
			if !matchesPattern(p.Terminal().LoginPrompt, c.prompt) || !matchesPattern(p.Terminal().CommandPrompt, c.prompt) {
				t.Fatal("prompt rejected")
			}
			match := false
			for _, r := range p.Terminal().CommandErrors {
				match = match || r.MatchString(c.diagnostic)
			}
			if !match {
				t.Fatal("diagnostic missed")
			}
			wantSave := c.name != "palo_alto" && c.name != "juniper" && c.name != "topsec"
			wantTFTP := c.name != "juniper" && c.name != "topsec"
			wantDesc := c.name != "topsec" && c.name != "centec"
			wantNeighbors := wantDesc && c.name != "radware"
			wantWrite := c.name == "h3c" || c.name == "h3c_wireless" || c.name == "cisco_ios" || c.name == "cisco_nxos" || c.name == "hillstone"
			declaration, err := NewBuiltinRegistry().Lookup(c.name)
			if err != nil {
				t.Fatal(err)
			}
			_, hasTFTP := declaration.(transfer.TFTPPolicy)
			_, hasDescriptions := declaration.(topology.DescriptionReader)
			_, hasNeighbors := declaration.(topology.NeighborDiscovery)
			_, hasWriter := declaration.(topology.DescriptionWriter)
			_, hasRemoteBackup := declaration.(transfer.RemoteBackupPolicy)
			hasSave := len(p.Terminal().SaveCommands) > 0
			if hasSave != wantSave || hasTFTP != wantTFTP || hasDescriptions != wantDesc || hasNeighbors != wantNeighbors || hasWriter != wantWrite || hasRemoteBackup != (c.name == "juniper") {
				t.Fatalf("platform behavior mismatch: save=%t tftp=%t descriptions=%t neighbors=%t writer=%t remote_backup=%t", hasSave, hasTFTP, hasDescriptions, hasNeighbors, hasWriter, hasRemoteBackup)
			}
			first := p.Terminal()
			first.ConfigCommands[0] = "mutated"
			if p.Terminal().ConfigCommands[0] == "mutated" {
				t.Fatal("shared mutable commands")
			}
			if p.NewConfigCollector() == p.NewConfigCollector() {
				t.Fatal("shared strategy")
			}
		})
	}
	if _, e := NewBuiltinRegistry().Lookup("paloalto"); !errors.Is(e, connector.ErrUnsupported) {
		t.Fatalf("unknown: %v", e)
	}
}
func TestInteractionsAndPrivilege(t *testing.T) {
	cases := []struct {
		vendor, input, want string
		login               bool
	}{
		{"h3c", "Are you sure? [Y/N]", "y\n", false}, {"h3c", "press the enter key)", "\n", false}, {"h3c", "Continue? [Y/N]", "y\n", false}, {"h3c", "Please input the file name(*.cfg)[startup.cfg]", "\n", false}, {"h3c", "overwrite? [Y/N]", "y\n", false},
		{"cisco_ios", "Destination filename [startup-config]?", "\n", false}, {"cisco_ios", "Do you want to overwrite? [yes/no]", "yes\n", false}, {"cisco_ios", "Proceed with copy? [confirm]", "\n", false},
		{"radware", "Confirm Sync to Peer [y/n]:", "y\n", false}, {"radware", "Synchronize configuration changes? [y/n]:", "y\n", false}, {"radware", "Confirm saving to FLASH [y/n]:", "y\n", false}, {"radware", "Confirm operation without applying changes (leave them pending) [y/n]:", "y\n", false}, {"radware", "Confirm operation without saving changes (leave them pending) [y/n]", "y\n", false}, {"radware", "Confirm seeing above note [y]:", "y\n", false}, {"radware", "Please enter y to perform the action, n to skip it:", "y\n", false}, {"radware", "Display private keys? [y/n]:", "n\n", false},
		{"palo_alto", "Please acknowledge this banner and enter yes", "yes\n", true}, {"fortinet", "Press any key to continue...", " ", true},
	}
	for _, c := range cases {
		t.Run(c.vendor+c.input, func(t *testing.T) {
			p := lookupPlatform(t, c.vendor)
			rules := p.Terminal().Interactions
			if c.login {
				rules = p.Terminal().LoginInteractions
			}
			got := ""
			for _, r := range rules {
				if matchesPattern(r.Pattern, c.input) {
					if r.Capture != (c.vendor != "fortinet") {
						t.Error("interaction capture differs from source")
					}
					if (c.login && r.Limit != 1) || (!c.login && r.Limit != 0) {
						t.Errorf("interaction limit %d differs from source", r.Limit)
					}
					got = r.Reply
					break
				}
			}
			if got != c.want {
				t.Fatalf("response %q, want %q", got, c.want)
			}
		})
	}
	p := lookupPlatform(t, "huawei")
	if p.Terminal().PrivilegeCommand != "su" || !matchesPattern(p.Terminal().PrivilegePrompt, "privilege level is 3\n<Huawei>") {
		t.Fatal("privilege")
	}
}

type hookExecutor struct {
	values   map[string]string
	commands []string
	err      error
}

func (x *hookExecutor) Value(k string) string { return x.values[k] }
func (x *hookExecutor) SetValue(k, v string)  { x.values[k] = v }
func (x *hookExecutor) Execute(_ context.Context, c connector.Command) (connector.StepResult, error) {
	x.commands = append(x.commands, c.Text)
	return connector.StepResult{}, x.err
}
func TestH3CRuleHook(t *testing.T) {
	p := lookupPlatform(t, "h3c")
	x := &hookExecutor{values: map[string]string{}}
	c := connector.Command{Text: "rule XXX append source-ip 192.0.2.1"}
	if _, _, e := p.(connector.CommandPreparer).PrepareCommand(t.Context(), c, x); e == nil {
		t.Fatal("unresolved ID accepted")
	}
	x.SetValue("rule_id", "123")
	got, skip, e := p.(connector.CommandPreparer).PrepareCommand(t.Context(), c, x)
	if e != nil || skip || got.Text != "rule 123 append source-ip 192.0.2.1" {
		t.Fatalf("%s %v %v", got.Text, skip, e)
	}
	x.err = errors.New("query failed")
	if e := p.(connector.CommandObserver).AfterCommand(t.Context(), connector.Command{Text: "rule pass source-ip any"}, connector.StepResult{}, x); !errors.Is(e, x.err) {
		t.Fatalf("query error lost: %v", e)
	}
	if !reflect.DeepEqual(x.commands, []string{"dis this"}) {
		t.Fatal(x.commands)
	}
}

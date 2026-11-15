package vendors

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/gatework/net-connector/connector"
)

type exchange struct{ send, receive string }

// Fixtures drive each platform dialogue through a full connector session.
func dialogue(t *testing.T, name, login string, events []exchange, configs ...connector.ConnectionConfig) (*connector.Device, func()) {
	t.Helper()
	p := lookupPlatform(t, name)
	done := make(chan error, 1)
	factory := func(context.Context, connector.ConnectionConfig) (io.ReadWriteCloser, error) {
		a, b := net.Pipe()
		go func() {
			defer b.Close()
			if _, e := io.WriteString(b, login); e != nil {
				done <- e
				return
			}
			for i, event := range events {
				buf := make([]byte, len(event.send))
				if _, e := io.ReadFull(b, buf); e != nil {
					done <- fmt.Errorf("exchange %d read: %w", i, e)
					return
				}
				if string(buf) != event.send {
					done <- fmt.Errorf("exchange %d command mismatch", i)
					return
				}
				if _, e := io.WriteString(b, event.receive); e != nil {
					done <- fmt.Errorf("exchange %d response: %w", i, e)
					return
				}
			}
			_, e := io.Copy(io.Discard, b)
			done <- e
		}()
		return a, nil
	}
	cfg := connector.ConnectionConfig{}
	if len(configs) > 0 {
		cfg = configs[0]
	}
	cfg.Host, cfg.LoginTimeout, cfg.CommandTimeout = "fixture", time.Second, time.Second
	d, e := connector.New(p, cfg, connector.WithTransportFactory(factory))
	if e != nil {
		t.Fatal(e)
	}
	checked := false
	check := func() {
		t.Helper()
		if checked {
			return
		}
		checked = true
		if e := d.Close(); e != nil {
			t.Error(e)
		}
		select {
		case e := <-done:
			if e != nil {
				t.Error(e)
			}
		case <-time.After(time.Second):
			t.Error("fixture peer did not exit")
		}
	}
	t.Cleanup(check)
	return d, check
}
func TestCollectionPlatformOutputsAndEchoOnly(t *testing.T) {
	prompts := map[string]string{"h3c": "<core>", "h3c_wireless": "[AC]", "huawei": "[Huawei]", "cisco_ios": "router#", "cisco_nxos": "nexus#", "centec": "Switch#", "hillstone": "stone(M)", "radware": ">> ADC - Main#", "topsec": "TopsecOS#", "fortinet": "FGT (root) #", "juniper": "audit@ex01>"}
	for name, prompt := range prompts {
		for _, empty := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/empty=%v", name, empty), func(t *testing.T) {
				p := lookupPlatform(t, name)
				events := []exchange{}
				last := ""
				for i, c := range p.Terminal().ConfigCommands {
					response := c + "\r\n"
					if i == len(p.Terminal().ConfigCommands)-1 && !empty {
						response += "hostname edge\r\n"
					}
					next := prompt
					if name == "radware" {
						next = ">> ADC - Configuration#"
					}
					response += next
					events = append(events, exchange{c + "\n", response})
					last = response
				}
				d, check := dialogue(t, name, prompt, events)
				r, e := d.RunningConfig(t.Context())
				if empty {
					if !errors.Is(e, connector.ErrIncomplete) {
						t.Fatalf("echo accepted: %v", e)
					}
					if _, ok := r.Config(); ok {
						t.Fatal("failed result has config")
					}
					if len(r.Steps()) != len(p.Terminal().ConfigCommands) {
						t.Fatalf("completed steps lost: %d", len(r.Steps()))
					}
				} else {
					if e != nil {
						t.Fatal(e)
					}
					want := strings.ReplaceAll(last, "\r\n", "\n")
					if name == "hillstone" {
						want = last
					}
					if name == "centec" {
						want = "hostname edge\n"
					}
					if config, ok := r.Config(); !ok || config != want {
						t.Fatalf("configuration %q want %q", config, want)
					}
				}
				check()
			})
		}
	}
}

func TestCollectionRejectsEchoOnlyWithRenderedPrompt(t *testing.T) {
	for _, fixture := range []struct {
		name, prompt string
	}{
		{"cisco_ios", "router# "},
		{"cisco_ios", "router#\t"},
		{"cisco_ios", "router#\r\n"},
		{"centec", "Switch# "},
		{"hillstone", "stone(M) "},
		{"h3c", "<core>\x00"},
	} {
		t.Run(fmt.Sprintf("%s/%q", fixture.name, fixture.prompt), func(t *testing.T) {
			p := lookupPlatform(t, fixture.name)
			var events []exchange
			for _, command := range p.Terminal().ConfigCommands {
				events = append(events, exchange{command + "\n", command + "\r\n" + fixture.prompt})
			}
			d, check := dialogue(t, fixture.name, fixture.prompt, events)
			result, err := d.RunningConfig(t.Context())
			if !errors.Is(err, connector.ErrIncomplete) {
				t.Fatalf("echo-only configuration accepted: %v", err)
			}
			if _, ok := result.Config(); ok || len(result.Steps()) != len(p.Terminal().ConfigCommands) {
				t.Fatal("configuration evidence or completed steps lost")
			}
			check()
		})
	}
}

func panEvents(show, before, after string) []exchange {
	return []exchange{{"set cli pager off\n", "admin@fw>"}, {"set cli config-output-format set\n", "admin@fw>"}, {"show config diff\n", "show config diff\n" + before + "admin@fw>"}, {"configure\n", "Entering configuration mode\nadmin@fw#"}, {"show\n", "show\n" + show + "\n[edit]\nadmin@fw#"}, {"exit\n", "Exiting configuration mode\nadmin@fw>"}, {"show config diff\n", "show config diff\n" + after + "admin@fw>"}}
}
func TestPANCollectionSelectsShowAndChecksBothDiffs(t *testing.T) {
	for _, c := range []struct {
		name, show, before, after string
		steps                     int
		good                      bool
	}{{"clean", "set system host-name fw", "", "", 7, true}, {"before", "", "+ changed\n", "", 3, false}, {"after", "set system host-name fw", "", "+ changed\n", 7, false}, {"xml", "<config/>", "", "", 7, false}, {"empty", "", "", "", 7, false}, {"quote", "set description \"truncated", "", "", 7, false}} {
		t.Run(c.name, func(t *testing.T) {
			events := panEvents(c.show, c.before, c.after)
			d, check := dialogue(t, "palo_alto", "admin@fw>", events[:c.steps])
			r, e := d.RunningConfig(t.Context())
			if c.good {
				if e != nil {
					t.Fatal(e)
				}
				if value, ok := r.Config(); !ok || value != c.show {
					t.Fatalf("selected %q", value)
				}
			} else if !errors.Is(e, connector.ErrIncomplete) {
				t.Fatalf("incomplete: %v", e)
			}
			if !c.good && d.Connected() {
				t.Error("failed collection left session connected")
			}
			if len(r.Steps()) != c.steps {
				t.Fatalf("steps %d want %d", len(r.Steps()), c.steps)
			}
			check()
		})
	}
}
func TestH3CAssignedRuleIDAndScope(t *testing.T) {
	d, check := dialogue(t, "h3c", "[core]", []exchange{{"rule pass source-ip any\n", "rule created\n[core]"}, {"dis this\n", "rule 123 pass source-ip any\n #\n[core]"}, {"rule 123 append destination-ip any\n", "done\n[core]"}})
	r, e := d.ExecuteScript(t.Context(), connector.Script{Commands: []connector.Command{{Text: "rule pass source-ip any"}, {Text: "rule XXX append destination-ip any"}}}, connector.ExecuteOptions{})
	if e != nil || len(r.Steps()) != 2 {
		t.Fatalf("steps %d %v", len(r.Steps()), e)
	}
	r, e = d.ExecuteCommand(t.Context(), connector.Command{Text: "rule XXX append destination-ip any"}, connector.ExecuteOptions{})
	if !errors.Is(e, connector.ErrIncomplete) || len(r.Steps()) != 0 {
		t.Fatalf("rule ID leaked to next script: %v", e)
	}
	check()
}
func TestHuaweiPrivilegeOncePerConnection(t *testing.T) {
	d, check := dialogue(t, "huawei", "<Huawei>", []exchange{{"su\n", "privilege level is 3\n<Huawei>"}, {"dis cur\n", "sysname Huawei\n<Huawei>"}, {"dis cur\n", "sysname Huawei\n<Huawei>"}})
	for range 2 {
		if _, e := d.RunningConfig(t.Context()); e != nil {
			t.Fatal(e)
		}
	}
	check()
}
func TestRadwareMenuIdentityPrivateKeysAndHA(t *testing.T) {
	d, check := dialogue(t, "radware", "HA State: ACTIVE\n>> Standalone ADC - Main#", []exchange{{"/cfg/dump\n", "Display private keys? [y/n]: "}, {"n\n", "/c/sys\n name adc\n#\n>> Another ADC - Configuration#\n/c/l3\n>> Standalone ADC - Configuration#"}, {"/cfg/dump\n", "/c/sys\n name adc\n#\n>> Standalone ADC - Configuration#"}})
	for i := range 2 {
		r, e := d.RunningConfig(t.Context())
		if e != nil {
			t.Fatal(e)
		}
		if i == 0 && !strings.Contains(testResultOutput(r), "/c/l3") {
			t.Fatal("wrong identity completed collection")
		}
		if d.LoginLabel("ha_state") != "ACTIVE" {
			t.Fatalf("HA = %q", d.LoginLabel("ha_state"))
		}
	}
	check()
	if d.LoginLabel("ha_state") != "" {
		t.Fatal("HA survived disconnect")
	}
}
func TestExplicitLifecycleValidatesBeforeConnect(t *testing.T) {
	calls := 0
	factory := func(context.Context, connector.ConnectionConfig) (io.ReadWriteCloser, error) {
		calls++
		return nil, errors.New("fixture")
	}
	if _, e := NewBuiltinRegistry().Lookup("unknown"); !errors.Is(e, connector.ErrUnsupported) || calls != 0 {
		t.Fatalf("unknown profile: %v", e)
	}
	p := lookupPlatform(t, "h3c")
	d, e := connector.New(p, connector.ConnectionConfig{Host: "fixture"}, connector.WithTransportFactory(factory))
	if e != nil {
		t.Fatal(e)
	}
	defer d.Close()
	if calls != 0 {
		t.Fatal("construction connected")
	}
	if e = d.Connect(t.Context()); e == nil || calls != 1 {
		t.Fatalf("connect calls=%d err=%v", calls, e)
	}
}

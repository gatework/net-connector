package topology_test

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"reflect"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gatework/net-connector/topology"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/vendors"
)

type fixture struct {
	mu                                              sync.Mutex
	vendor                                          string
	device                                          *connector.Device
	topology                                        *topology.Client
	desc, neighbor, iface, mode, saveOutput, failOn string
	mismatch, partial                               bool
	writes                                          []string
	onCommand                                       func(string)
	done                                            chan struct{}
	opens                                           int
}

var fixtureNeighborCommands = map[string]string{"h3c": "display lldp neighbor-information list", "h3c_wireless": "display lldp neighbor-information list", "huawei": "display lldp neighbor brief", "cisco_ios": "show cdp neighbors detail", "cisco_nxos": "show cdp neighbors detail", "hillstone": "show lldp neighbor-information", "palo_alto": "show lldp neighbors all", "juniper": "show lldp neighbors detail | no-more"}

func newFixture(t *testing.T, vendor string) *fixture {
	t.Helper()
	f := &fixture{vendor: vendor, desc: "original", mode: "exec", done: make(chan struct{})}
	switch vendor {
	case "h3c", "h3c_wireless":
		f.iface = "GigabitEthernet1/0/1"
		f.neighbor = "Local Interface Chassis ID Port ID System Name\nGE1/0/1 000f-e25d-ee91 GE1/0/2 peer\n"
		f.saveOutput = "Saved the current configuration to mainboard device successfully."
	case "hillstone":
		f.iface = "ethernet0/1"
		f.neighbor = "System Name Local Interface Chassis ID Port ID\npeer ethernet0/1 7425.8ae4.4f4c ethernet0/2\nTotal lldp neighbor number: 1.\n"
		f.saveOutput = "Saving configuration is finished"
	default:
		f.iface = "GigabitEthernet1/0/1"
		f.neighbor = "Device ID: peer\nInterface: GigabitEthernet1/0/1, Port ID (outgoing port): GigabitEthernet1/0/2\n"
		f.saveOutput = "[OK]"
	}
	p := platformProfile(vendor)
	factory := func(context.Context, connector.ConnectionConfig) (io.ReadWriteCloser, error) {
		f.opens++
		a, b := net.Pipe()
		go func() {
			defer close(f.done)
			defer b.Close()
			io.WriteString(b, f.prompt())
			scanner := bufio.NewScanner(b)
			for scanner.Scan() {
				command := scanner.Text()
				f.mu.Lock()
				f.writes = append(f.writes, command)
				f.mu.Unlock()
				if f.onCommand != nil {
					f.onCommand(command)
				}
				if command == f.failOn {
					return
				}
				body := ""
				switch {
				case command == fixtureNeighborCommands[vendor]:
					body = f.neighbor
				case command == p.Terminal().ConfigCommands[len(p.Terminal().ConfigCommands)-1]:
					ending := "!\nend"
					if vendor == "h3c" || vendor == "h3c_wireless" {
						ending = "#"
					}
					if vendor == "hillstone" {
						ending = "exit"
					}
					body = "interface " + f.iface + "\n description " + f.desc + "\n" + ending + "\n"
					if f.partial && f.desc == "planned" {
						body += "interface malformed extra fields\n description ignored\n"
					}
				case command == p.Terminal().SaveCommands[0]:
					body = f.saveOutput
				case command == "system-view" || command == "configure" || command == "configure terminal":
					f.mode = "config"
				case strings.HasPrefix(command, "interface "):
					f.mode = "interface"
				case strings.HasPrefix(command, "description "):
					if !f.mismatch {
						f.desc = strings.TrimPrefix(command, "description ")
					}
				case command == "return" || command == "end":
					f.mode = "exec"
				case command == "exit" || command == "quit":
					if f.mode == "interface" {
						f.mode = "config"
					} else {
						f.mode = "exec"
					}
				}
				if _, e := io.WriteString(b, command+"\r\n"+strings.ReplaceAll(body, "\n", "\r\n")+"\r\n"+f.prompt()); e != nil {
					return
				}
			}
		}()
		return a, nil
	}
	device, e := connector.New(p, connector.ConnectionConfig{Host: "fixture", CommandTimeout: time.Second, LoginTimeout: time.Second}, connector.WithTransportFactory(factory))
	if e != nil {
		t.Fatal(e)
	}
	f.device = device
	f.topology, e = topology.New(f.device, vendors.NewBuiltinRegistry())
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() {
		f.device.Close()
		if f.opens > 0 {
			select {
			case <-f.done:
			case <-time.After(time.Second):
				t.Error("fixture leaked")
			}
		}
	})
	return f
}

func platformProfile(vendor string) platform.Platform {
	declaration, err := vendors.NewBuiltinRegistry().Lookup(vendor)
	if err != nil {
		panic(err)
	}
	return declaration
}
func (f *fixture) prompt() string {
	if f.vendor == "h3c" || f.vendor == "h3c_wireless" {
		if f.mode == "exec" {
			return "<switch>"
		}
		return "[switch]"
	}
	switch f.mode {
	case "config":
		return "switch(config)#"
	case "interface":
		return "switch(config-if)#"
	}
	return "switch#"
}
func (f *fixture) sent() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.writes)
}
func planned(topology.Neighbor) (string, error) { return "planned", nil }
func TestApplyRevalidatesChangesReadsBackThenSaves(t *testing.T) {
	for _, vendor := range []string{"h3c", "h3c_wireless", "cisco_ios", "cisco_nxos", "hillstone"} {
		t.Run(vendor, func(t *testing.T) {
			f := newFixture(t, vendor)
			p, e := planTopology(f.topology, topology.FormatOptions{Formatter: planned})
			if e != nil {
				t.Fatal(e)
			}
			start := len(f.sent())
			r, e := f.topology.Apply(context.Background(), p, topology.ApplyOptions{Confirmed: true})
			if e != nil || !r.Persisted || !r.Verified {
				t.Fatalf("%#v %v", r, e)
			}
			expected := append([]string{fixtureNeighborCommands[vendor]}, f.device.ConfigCommands()...)
			expected = append(expected, p.Commands...)
			if !reflect.DeepEqual(f.sent()[start:], expected) {
				t.Fatalf("commands: %q want %q", f.sent()[start:], expected)
			}
			if len(r.Steps()) != len(expected) {
				t.Fatalf("receipts %d commands %d", len(r.Steps()), len(expected))
			}
			if f.opens != 1 {
				t.Fatal("reopened")
			}
		})
	}
}
func TestApplyPreflightAndStaleRefusal(t *testing.T) {
	for _, fault := range []string{"confirmation", "forged", "duplicate", "description", "chassis"} {
		t.Run(fault, func(t *testing.T) {
			f := newFixture(t, "h3c")
			p, e := planTopology(f.topology, topology.FormatOptions{Formatter: planned})
			if e != nil {
				t.Fatal(e)
			}
			start := len(f.sent())
			confirmed := true
			switch fault {
			case "confirmation":
				confirmed = false
			case "forged":
				p.Commands = append(p.Commands, "save again")
			case "duplicate":
				p.Changes = append(p.Changes, p.Changes[0])
			case "description":
				f.desc = "external"
			case "chassis":
				f.neighbor = strings.ReplaceAll(f.neighbor, "000f-e25d-ee91", "000f-e25d-ee92")
			}
			r, e := f.topology.Apply(context.Background(), p, topology.ApplyOptions{Confirmed: confirmed})
			if e == nil {
				t.Fatal("accepted fault")
			}
			sent := f.sent()[start:]
			for _, c := range sent {
				if c == "system-view" || strings.HasPrefix(c, "description ") {
					t.Fatal("write after stale or invalid plan")
				}
			}
			if fault == "description" || fault == "chassis" {
				if !errors.Is(e, topology.ErrStale) || len(r.Receipts) == 0 {
					t.Fatalf("lost stale receipts: %#v %v", r, e)
				}
			} else if len(sent) != 0 {
				t.Fatal("preflight did IO")
			}
		})
	}
}
func TestApplyReadbackFailuresNeverSave(t *testing.T) {
	for _, fault := range []string{"mismatch", "partial", "change_eof", "verify_eof", "persist_eof", "prompt_only", "hidden_failure"} {
		t.Run(fault, func(t *testing.T) {
			f := newFixture(t, "cisco_ios")
			p, e := planTopology(f.topology, topology.FormatOptions{Formatter: planned})
			if e != nil {
				t.Fatal(e)
			}
			switch fault {
			case "mismatch":
				f.mismatch = true
			case "partial":
				f.partial = true
			case "change_eof":
				f.failOn = "description planned"
			case "verify_eof":
				f.onCommand = func(c string) {
					if c == "description planned" {
						f.failOn = "show running-config"
					}
				}
			case "persist_eof":
				f.failOn = "copy running-config startup-config"
			case "prompt_only":
				f.saveOutput = ""
			case "hidden_failure":
				f.saveOutput = "\x1b[31mError\x1b[0m private-marker\r\x1b[2K[OK]"
			}
			r, e := f.topology.Apply(context.Background(), p, topology.ApplyOptions{Confirmed: true})
			if e == nil || len(r.Receipts) == 0 || r.Persisted {
				t.Fatalf("%#v %v", r, e)
			}
			if strings.Contains(fmt.Sprintf("%#v", e), "private-marker") {
				t.Fatal("raw error leaked")
			}
			n := 0
			for _, c := range f.sent() {
				if c == "copy running-config startup-config" {
					n++
				}
			}
			expected := 0
			if fault == "persist_eof" || fault == "prompt_only" || fault == "hidden_failure" {
				expected = 1
				if !errors.Is(e, topology.ErrPersistence) {
					t.Fatalf("wrong persist error %v", e)
				}
			}
			if n != expected {
				t.Fatalf("save count %d", n)
			}
		})
	}
}
func TestSyncNoOpAndLeaseCoversAllPhases(t *testing.T) {
	f := newFixture(t, "cisco_ios")
	f.onCommand = func(string) {
		_, e := f.device.ExecuteCommand(context.Background(), connector.Command{Text: "competing"}, connector.ExecuteOptions{})
		if !errors.Is(e, connector.ErrBusy) {
			t.Errorf("lease released: %v", e)
		}
	}
	r, e := syncTopology(f.topology, topology.FormatOptions{Formatter: planned})
	if e != nil || !r.Persisted {
		t.Fatalf("%#v %v", r, e)
	}
	start := len(f.sent())
	r, e = syncTopology(f.topology, topology.FormatOptions{Formatter: planned})
	if e != nil || r.Persisted {
		t.Fatalf("no-op %#v %v", r, e)
	}
	for _, c := range f.sent()[start:] {
		if c == "configure terminal" || c == "copy running-config startup-config" {
			t.Fatal("no-op wrote")
		}
	}
}

func TestPersistenceCallbackFailureRetainsPrimaryErrorAndCompletedSave(t *testing.T) {
	f := newFixture(t, "cisco_ios")
	p, e := planTopology(f.topology, topology.FormatOptions{Formatter: planned})
	if e != nil {
		t.Fatal(e)
	}
	primary := errors.New("private callback failure")
	r, e := f.topology.Apply(context.Background(), p, topology.ApplyOptions{Confirmed: true, Execute: connector.ExecuteOptions{OnReceipt: func(_ context.Context, s connector.StepResult) error {
		if s.Command().Text == "copy running-config startup-config" {
			return primary
		}
		return nil
	}}})
	if !errors.Is(e, primary) || !errors.Is(e, topology.ErrPersistence) {
		t.Fatalf("primary lost: %v", e)
	}
	steps := r.Steps()
	if len(steps) == 0 || steps[len(steps)-1].Command().Text != "copy running-config startup-config" {
		t.Fatal("completed save receipt lost")
	}
	if strings.Contains(fmt.Sprintf("%+v", e), "private callback") {
		t.Fatal("callback diagnostic leaked")
	}
}
func TestReadOnlyAndUnsupportedOperationsAreOffline(t *testing.T) {
	for _, vendor := range []string{"huawei", "fortinet", "juniper", "palo_alto", "radware", "topsec", "centec"} {
		t.Run(vendor, func(t *testing.T) {
			profile := platformProfile(vendor)
			opened := 0
			d, e := connector.New(profile, connector.ConnectionConfig{Host: "fixture"}, connector.WithTransportFactory(func(context.Context, connector.ConnectionConfig) (io.ReadWriteCloser, error) {
				opened++
				return nil, errors.New("must stay offline")
			}))
			if e != nil {
				t.Fatal(e)
			}
			top, e := topology.New(d, vendors.NewBuiltinRegistry())
			if e != nil {
				t.Fatal(e)
			}
			if _, e = planTopology(top, topology.FormatOptions{}); !errors.Is(e, topology.ErrUnsupported) {
				t.Fatalf("plan: %v", e)
			}
			if _, e = syncTopology(top, topology.FormatOptions{}); !errors.Is(e, topology.ErrUnsupported) {
				t.Fatalf("sync: %v", e)
			}
			if opened != 0 {
				t.Fatal("opened unsupported device")
			}
		})
	}
}

func TestTopologyRejectsBehaviorsNotDeclaredByPlatform(t *testing.T) {
	profile := platformProfile("topsec")
	opened := 0
	device, err := connector.New(profile, connector.ConnectionConfig{Host: "fixture"}, connector.WithTransportFactory(func(context.Context, connector.ConnectionConfig) (io.ReadWriteCloser, error) {
		opened++
		return nil, errors.New("unsupported platform must stay offline")
	}))
	if err != nil {
		t.Fatal(err)
	}
	top, err := topology.New(device, vendors.NewBuiltinRegistry())
	if err != nil {
		t.Fatal(err)
	}
	if _, err = top.Audit(context.Background(), topology.FormatOptions{}); !errors.Is(err, topology.ErrUnsupported) {
		t.Fatalf("audit: %v", err)
	}
	if _, err = top.Discover(context.Background()); !errors.Is(err, topology.ErrUnsupported) {
		t.Fatalf("discover: %v", err)
	}
	if opened != 0 {
		t.Fatalf("opened unsupported device %d times", opened)
	}
	_ = device.Close()
}

func TestFortinetVersionAndAuthorizedViewSelection(t *testing.T) {
	for _, tc := range []struct {
		version, view, statusView, command string
		valid                              bool
	}{{"7.6.2", "root", "root", "diagnose lldprx neighbor", true}, {"7.6.3", "root", "root", "diagnose lldp rx neighbor", true}, {"8.0.0", "tenant", "tenant", "diagnose lldp rx neighbor", true}, {"unknown", "root", "root", "", false}, {"7.6.3", "tenant", "other", "", false}} {
		t.Run(tc.version+tc.view+tc.statusView, func(t *testing.T) {
			profile := platformProfile("fortinet")
			done := make(chan error, 1)
			sent := []string{}
			factory := func(context.Context, connector.ConnectionConfig) (io.ReadWriteCloser, error) {
				a, b := net.Pipe()
				go func() {
					defer b.Close()
					prompt := "FGT (" + tc.view + ") #"
					io.WriteString(b, prompt)
					scan := bufio.NewScanner(b)
					for scan.Scan() {
						command := scan.Text()
						sent = append(sent, command)
						var body string
						switch command {
						case "get system status":
							body = "Version: FortiGate v" + tc.version + ",build001\r\nCurrent virtual domain: " + tc.statusView + "\r\n"
						case tc.command:
							body = "No LLDP neighbors.\r\n"
						default:
							done <- errors.New("unexpected command")
							return
						}
						if _, e := io.WriteString(b, command+"\r\n"+body+prompt); e != nil {
							break
						}
					}
					done <- nil
				}()
				return a, nil
			}
			d, e := connector.New(profile, connector.ConnectionConfig{Host: "fixture", CommandTimeout: time.Second}, connector.WithTransportFactory(factory))
			if e != nil {
				t.Fatal(e)
			}
			top, e := topology.New(d, vendors.NewBuiltinRegistry())
			if e != nil {
				t.Fatal(e)
			}
			peers, r, e := topology.NeighborsOnly(top)
			if tc.valid && (e != nil || len(peers) != 0 || len(r.Receipts) != 2) {
				t.Fatalf("%#v %v", r, e)
			}
			if !tc.valid && (e == nil || len(r.Receipts) != 1) {
				t.Fatalf("invalid version/context accepted: %v", e)
			}
			if !tc.valid {
				var diagnostic *topology.Error
				want := "unrecognized_output"
				if tc.version == "7.6.3" && tc.view == "tenant" {
					want = "vdom_context_mismatch"
				}
				if !errors.As(e, &diagnostic) || diagnostic.Code != want || diagnostic.Phase != "discover" {
					t.Fatalf("diagnostic = %#v, %v; want %q/discover", diagnostic, e, want)
				}
			}
			d.Close()
			select {
			case e := <-done:
				if e != nil {
					t.Fatal(e)
				}
			case <-time.After(time.Second):
				t.Fatal("fixture leaked")
			}
			expected := []string{"get system status"}
			if tc.valid {
				expected = append(expected, tc.command)
			}
			if !reflect.DeepEqual(sent, expected) {
				t.Fatalf("got commands %q want %q", sent, expected)
			}
		})
	}
}

func TestAuditPlanRevalidatesOnlyVerifiedInterfaces(t *testing.T) {
	f := newFixture(t, "cisco_ios")
	a, e := f.topology.Audit(context.Background(), topology.FormatOptions{Formatter: planned})
	if e != nil || a.Plan == nil {
		t.Fatalf("%#v %v", a, e)
	}
	f.neighbor += "Device ID: another\nInterface: Gi1/2, Port ID (outgoing port): Gi1/3\n"
	r, e := f.topology.Apply(context.Background(), *a.Plan, topology.ApplyOptions{Confirmed: true})
	if e != nil || !r.Persisted {
		t.Fatalf("scoped plan refused unrelated neighbor: %#v %v", r, e)
	}
}
func TestReadOnlyPlatformCandidateErrorCode(t *testing.T) {
	for _, v := range []string{"palo_alto", "juniper"} {
		p := platformProfile(v)
		d, _ := connector.New(p, connector.ConnectionConfig{Host: "fixture"})
		top, _ := topology.New(d, vendors.NewBuiltinRegistry())
		_, e := syncTopology(top, topology.FormatOptions{})
		var domain *topology.Error
		if !errors.As(e, &domain) || domain.Code != "candidate_isolation_unavailable" {
			t.Fatalf("%s error %v", v, e)
		}
	}
}

func TestEveryWritePlatformStopsAtEachFailedStage(t *testing.T) {
	for _, vendor := range []string{"h3c", "h3c_wireless", "cisco_ios", "cisco_nxos", "hillstone"} {
		for _, phase := range []string{"enter", "change", "leave", "verify", "persist"} {
			t.Run(vendor+"/"+phase, func(t *testing.T) {
				f := newFixture(t, vendor)
				p, e := planTopology(f.topology, topology.FormatOptions{Formatter: planned})
				if e != nil {
					t.Fatal(e)
				}
				start := len(f.sent())
				change, verify, persist, e := topology.StageCommands(f.topology, p.Changes)
				if e != nil {
					t.Fatal(e)
				}
				target := ""
				switch phase {
				case "enter":
					target = change[0]
				case "change":
					target = "description planned"
				case "leave":
					target = change[len(change)-1]
				case "verify":
					target = verify[len(verify)-1]
				case "persist":
					target = persist[0]
				}
				if phase == "verify" {
					f.onCommand = func(c string) {
						if c == "description planned" {
							f.failOn = target
						}
					}
				} else {
					f.failOn = target
				}
				r, e := f.topology.Apply(context.Background(), p, topology.ApplyOptions{Confirmed: true})
				if e == nil || r.Persisted {
					t.Fatalf("failure accepted: %#v %v", r, e)
				}
				sent := f.sent()[start:]
				if len(sent) == 0 || sent[len(sent)-1] != target {
					t.Fatalf("continued beyond failed stage: %q", sent)
				}
				if len(r.Receipts) != len(sent)-1 {
					t.Fatalf("completed prefix lost: %d receipts, %d sends", len(r.Receipts), len(sent))
				}
				for i, step := range r.Receipts {
					if step.Command().Text != sent[i] {
						t.Fatalf("receipt %d not completed command", i)
					}
				}
			})
		}
	}
}
func TestDiscoveryPublicBoundariesAndParsingFailureReceipts(t *testing.T) {
	f := newFixture(t, "cisco_ios")
	s, e := f.topology.Discover(context.Background())
	if e != nil || s.Descriptions["gigabitethernet1/0/1"] != "original" {
		t.Fatalf("descriptions %#v %v", s, e)
	}
	s, e = f.topology.Discover(context.Background())
	if e != nil || len(s.Neighbors) != 1 || len(s.Receipts) != 3 {
		t.Fatalf("snapshot %#v %v", s, e)
	}
	f.neighbor = "Device ID: partial\n"
	s, e = f.topology.Discover(context.Background())
	if !errors.Is(e, topology.ErrParse) || len(s.Receipts) != 1 {
		t.Fatalf("parse lost collection receipt: %#v %v", s, e)
	}
}
func TestApplySnapshotsPlanBeforeCallbacks(t *testing.T) {
	f := newFixture(t, "cisco_ios")
	p, e := planTopology(f.topology, topology.FormatOptions{Formatter: planned})
	if e != nil {
		t.Fatal(e)
	}
	mutated := false
	r, e := f.topology.Apply(context.Background(), p, topology.ApplyOptions{Confirmed: true, Execute: connector.ExecuteOptions{OnReceipt: func(context.Context, connector.StepResult) error {
		if !mutated {
			p.Commands[0] = "bad"
			p.Changes[0].NewDescription = "mutated"
			clear(p.Evidence)
			mutated = true
		}
		return nil
	}}})
	if e != nil || !r.Persisted || f.desc != "planned" {
		t.Fatalf("plan mutation altered apply: %#v %v", r, e)
	}
}

func TestAuditFormatterFailurePreservesCollectionReceipts(t *testing.T) {
	f := newFixture(t, "cisco_ios")
	primary := errors.New("private formatter unavailable")
	a, err := f.topology.Audit(t.Context(), topology.FormatOptions{Formatter: func(topology.Neighbor) (string, error) { return "", primary }})
	if !errors.Is(err, primary) || len(a.Receipts) != 3 || a.Plan != nil {
		t.Fatalf("audit failure lost evidence: %#v %v", a, err)
	}
	want := append([]string{fixtureNeighborCommands["cisco_ios"]}, f.device.ConfigCommands()...)
	for i, receipt := range a.Receipts {
		if receipt.Command().Text != want[i] {
			t.Fatalf("receipt %d: %v", i, receipt.Command())
		}
	}
}

// planTopology plans a description change as the workflow does: one audit
// lease, whose plan exists only for platforms that can write.
func planTopology(c *topology.Client, opts topology.FormatOptions) (topology.Plan, error) {
	if err := topology.SupportsWrite(c); err != nil {
		return topology.Plan{}, err
	}
	a, err := c.Audit(context.Background(), opts)
	if err != nil || a.Plan == nil {
		return topology.Plan{Receipts: a.Receipts}, err
	}
	return *a.Plan, nil
}

// syncTopology audits, then applies the resulting plan with confirmation.
func syncTopology(c *topology.Client, opts topology.FormatOptions) (topology.Result, error) {
	p, err := planTopology(c, opts)
	if err != nil {
		return topology.Result{}, err
	}
	return c.Apply(context.Background(), p, topology.ApplyOptions{Confirmed: true})
}

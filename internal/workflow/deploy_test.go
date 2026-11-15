package workflow_test

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	expect "github.com/gatework/go-expect"

	"github.com/gatework/net-connector/config"
	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/fleet"
	"github.com/gatework/net-connector/internal/batchreport"
	"github.com/gatework/net-connector/internal/bootstrap"
	"github.com/gatework/net-connector/internal/workflow"
	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/transfer"
)

func mustPattern(t *testing.T, expression string) expect.Pattern {
	t.Helper()
	p, err := expect.Compile(expression)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// fakeSwitch answers every line with its echo, an optional response and the
// prompt. Lines containing "bad" are rejected; "write memory" replies with
// saveReply. It records every line it received.
type fakeSwitch struct {
	saveReply string
	// failConfig makes the device reject "show running-config".
	failConfig bool
	mu         sync.Mutex
	received   map[string][]string
}

func (f *fakeSwitch) lines(host string) []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Clone(f.received[host])
}

func (f *fakeSwitch) opener(t *testing.T, opened *atomic.Int32) workflow.DeviceOpener {
	t.Helper()
	return func(_ context.Context, r fleet.Record, logger io.Writer, _ workflow.SessionObserver) (*connector.Device, error) {
		opened.Add(1)
		profile := connector.StaticDriver{
			Grammar: connector.Terminal{
				Name: r.Platform, LoginPrompt: mustPattern(t, `sw#\s*\z`), CommandPrompt: mustPattern(t, `sw#\s*\z`),
				CommandErrors:  []*regexp.Regexp{regexp.MustCompile(`(?m)^% Invalid input`)},
				SaveCommands:   []string{"write memory"},
				ConfigCommands: []string{"show running-config"},
			},
			Save: func(_ context.Context, result connector.Result) error {
				out, err := result.JoinedOutput()
				if err != nil || !strings.Contains(out, "[OK]") {
					return connector.ErrUnconfirmed
				}
				return nil
			},
		}
		config := connector.ConnectionConfig{Host: r.Host, Username: "operator", Password: "secret", Protocol: connector.ProtocolSSH, Logger: logger}
		return connector.New(profile, config, connector.WithTransportFactory(func(context.Context, connector.ConnectionConfig) (io.ReadWriteCloser, error) {
			a, b := net.Pipe()
			go func() {
				defer b.Close()
				_, _ = io.WriteString(b, "sw#")
				reader := bufio.NewReader(b)
				var configured []string
				for {
					line, err := reader.ReadString('\n')
					if err != nil {
						return
					}
					line = strings.TrimRight(line, "\r\n")
					f.mu.Lock()
					f.received[r.Host] = append(f.received[r.Host], line)
					f.mu.Unlock()
					reply := ""
					switch {
					case strings.Contains(line, "bad"), line == "show running-config" && f.failConfig:
						reply = "% Invalid input detected\r\n"
					case line == "write memory":
						reply = f.saveReply + "\r\n"
					case line == "show running-config":
						reply = "hostname sw\r\ninterface Gi0/1\r\n"
						for _, applied := range configured {
							reply += applied + "\r\n"
						}
					default:
						// An accepted configuration line shows up in later collections.
						configured = append(configured, line)
					}
					if _, err = io.WriteString(b, line+"\r\n"+reply+"sw#"); err != nil {
						return
					}
				}
			}()
			return a, nil
		}))
	}
}

func testServices(t *testing.T) *bootstrap.Services {
	t.Helper()
	root := t.TempDir()
	defaults := config.Defaults("backup")
	defaults["backup"].(map[string]any)["directory"] = filepath.Join(root, "backups")
	p, err := config.Load(context.Background(), config.Options{Name: "backup", CWD: root, Home: root, Directories: []string{}, Environment: map[string]string{}, Defaults: defaults, AllowMissing: true})
	if err != nil {
		t.Fatal(err)
	}
	s, err := bootstrap.New(p, nil)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

// deployRuntime returns rows unchanged with a runtime that writes no session logs.
func deployRuntime(t *testing.T, rows []inventory.Device) ([]inventory.Device, workflow.Runtime) {
	t.Helper()
	runtime := testServices(t).WorkflowRuntime()
	runtime.LogDirectory = nil
	return rows, runtime
}

func parseScript(t *testing.T, text string) connector.Script {
	t.Helper()
	script, err := connector.ParseScript(text, "change.txt")
	if err != nil {
		t.Fatal(err)
	}
	return script
}

func TestDeployPlanNeverOpensDevicesAndSkipsPlatformsWithoutScript(t *testing.T) {
	rows, runtime := deployRuntime(t, []inventory.Device{{IP: "192.0.2.1", Vendor: "cisco", OS: "ios"}, {IP: "192.0.2.2", Vendor: "huawei"}})
	var opened atomic.Int32
	runtime.OpenDevice = (&fakeSwitch{received: map[string][]string{}}).opener(t, &opened)
	scripts := workflow.DeployScripts{ByPlatform: map[string]connector.Script{"cisco_ios": parseScript(t, "interface Gi0/1\n description uplink\n")}}
	result, err := (&workflow.Runner{}).Deploy(t.Context(), runtime, rows, workflow.DeployOptions{Scripts: scripts, Plan: true, Directory: t.TempDir(), Policy: "selected"})
	if err != nil || opened.Load() != 0 || !result.Planned {
		t.Fatalf("plan opened %d devices: %v", opened.Load(), err)
	}
	devices := result.Report.Devices
	if devices[0].Status != batchreport.StatusNotStarted || devices[0].Target.Script != "change.txt" || devices[0].Target.Commands != 2 || devices[1].Status != "missing_script" {
		t.Fatalf("unexpected plan: %+v", devices)
	}
}

func TestDeployRecordsRejectionWithoutSendingLaterCommands(t *testing.T) {
	rows, runtime := deployRuntime(t, []inventory.Device{{IP: "192.0.2.1", Vendor: "cisco", OS: "ios"}, {IP: "192.0.2.2", Vendor: "cisco", OS: "ios"}})
	fake := &fakeSwitch{saveReply: "[OK]", received: map[string][]string{}}
	var opened atomic.Int32
	runtime.OpenDevice = fake.opener(t, &opened)
	runtime.Workers = 1
	good := parseScript(t, "vlan 10\nname users\n")
	result, err := (&workflow.Runner{}).Deploy(t.Context(), runtime, rows, workflow.DeployOptions{Scripts: workflow.DeployScripts{Default: &good}, Save: true, Snapshot: true, Directory: t.TempDir(), Policy: "selected"})
	if err != nil || !result.Success || result.Report.Counts[batchreport.StatusSucceeded] != 2 {
		t.Fatalf("deploy failed: %v %+v", err, result.Report)
	}
	first := result.Report.Devices[0]
	if strings.Join(stageNames(first), ",") != "authenticate,snapshot_before,execute,save,snapshot_after,diff" || first.Outcome != "deployed" || !first.Artifacts.Save.Confirmed || first.Artifacts.Backup == nil || first.Artifacts.Backup.Bytes == 0 {
		t.Fatalf("pipeline evidence: %+v", first)
	}
	if lines := fake.lines("192.0.2.1"); strings.Join(lines, "|") != "show running-config|vlan 10|name users|write memory|show running-config" {
		t.Fatalf("unexpected device input: %q", lines)
	}

	bad := parseScript(t, "vlan 20\nbad command\nname never-sent\n")
	fake.received = map[string][]string{}
	result, err = (&workflow.Runner{}).Deploy(t.Context(), runtime, rows, workflow.DeployOptions{Scripts: workflow.DeployScripts{Default: &bad}, Save: true, Snapshot: true, Directory: t.TempDir(), Policy: "selected"})
	if err != nil || result.Success {
		t.Fatalf("rejected deploy reported success: %v", err)
	}
	out := result.Report.Devices[0]
	script := out.Artifacts.Script
	if out.Status != batchreport.StatusPartial || out.FailedStage != "execute" || out.Outcome != "rejected" || out.Diagnostic.Code != "device_error" || script.Accepted != 1 || script.FailedLine != 2 || len(script.Attempts) != 2 || !script.Attempts[1].Failed || script.Attempts[1].Written == 0 {
		t.Fatalf("rejection evidence lost: %+v %+v", out, script)
	}
	if got := stageStatuses(out); got != "authenticate:succeeded,snapshot_before:succeeded,execute:failed,save:skipped,snapshot_after:skipped,diff:skipped" {
		t.Fatalf("later stages ran: %s", got)
	}
	if lines := fake.lines("192.0.2.1"); strings.Join(lines, "|") != "show running-config|vlan 20|bad command" {
		t.Fatalf("commands after a rejection were sent: %q", lines)
	}
}

func TestDeploySaveWithoutConfirmationIsPartial(t *testing.T) {
	rows, runtime := deployRuntime(t, []inventory.Device{{IP: "192.0.2.1", Vendor: "cisco", OS: "ios"}})
	var opened atomic.Int32
	runtime.OpenDevice = (&fakeSwitch{saveReply: "Building configuration...", received: map[string][]string{}}).opener(t, &opened)
	script := parseScript(t, "vlan 30\n")
	result, err := (&workflow.Runner{}).Deploy(t.Context(), runtime, rows, workflow.DeployOptions{Scripts: workflow.DeployScripts{Default: &script}, Save: true, Directory: t.TempDir(), Policy: "selected"})
	if err != nil || result.Success {
		t.Fatalf("unconfirmed save reported success: %v", err)
	}
	out := result.Report.Devices[0]
	if out.Status != batchreport.StatusPartial || out.FailedStage != "save" || out.Artifacts.Save.Confirmed || out.Artifacts.Script.Accepted != 1 {
		t.Fatalf("unexpected outcome: %+v", out)
	}
}

func TestDeployStopsStartingDevicesAfterFailureLimit(t *testing.T) {
	rows, runtime := deployRuntime(t, []inventory.Device{{IP: "192.0.2.1", Vendor: "cisco", OS: "ios"}, {IP: "192.0.2.2", Vendor: "cisco", OS: "ios"}, {IP: "192.0.2.3", Vendor: "cisco", OS: "ios"}})
	var opened atomic.Int32
	runtime.OpenDevice = func(context.Context, fleet.Record, io.Writer, workflow.SessionObserver) (*connector.Device, error) {
		opened.Add(1)
		return nil, fleet.ErrMissingCredentials
	}
	runtime.Workers = 1
	script := parseScript(t, "vlan 40\n")
	result, err := (&workflow.Runner{}).Deploy(t.Context(), runtime, rows, workflow.DeployOptions{Scripts: workflow.DeployScripts{Default: &script}, StopAfterFailures: 1, Directory: t.TempDir(), Policy: "selected"})
	if err != nil || result.Success || opened.Load() != 1 {
		t.Fatalf("failure limit ignored: opened=%d err=%v", opened.Load(), err)
	}
	report := result.Report
	first := report.Devices[0]
	if !report.Stopped || report.Counts[batchreport.StatusFailed] != 1 || report.Counts[batchreport.StatusStopped] != 2 || first.FailedStage != "authenticate" || first.Diagnostic.Code != "missing_credentials" {
		t.Fatalf("unexpected report: %+v", report)
	}
}

func TestDeployRejectsNegativeFailureLimit(t *testing.T) {
	rows, runtime := deployRuntime(t, []inventory.Device{{IP: "192.0.2.1", Vendor: "cisco", OS: "ios"}})
	_, err := (&workflow.Runner{}).Deploy(t.Context(), runtime, rows, workflow.DeployOptions{StopAfterFailures: -1, Directory: t.TempDir()})
	if !errors.Is(err, workflow.ErrInvalidRequest) {
		t.Fatalf("negative limit accepted: %v", err)
	}
}

func TestDeployWithSaveSkipsPlatformsWithoutSaveScript(t *testing.T) {
	rows, runtime := deployRuntime(t, []inventory.Device{{IP: "192.0.2.1", Vendor: "topsec"}, {IP: "192.0.2.2", Vendor: "cisco", OS: "ios"}})
	var opened atomic.Int32
	runtime.OpenDevice = (&fakeSwitch{saveReply: "[OK]", received: map[string][]string{}}).opener(t, &opened)
	script := parseScript(t, "set system ntp server 192.0.2.50\n")
	result, err := (&workflow.Runner{}).Deploy(t.Context(), runtime, rows, workflow.DeployOptions{Scripts: workflow.DeployScripts{Default: &script}, Save: true, Directory: t.TempDir(), Policy: "selected"})
	if err != nil || opened.Load() != 1 {
		t.Fatalf("opened=%d err=%v", opened.Load(), err)
	}
	if got := result.Report.Devices[0].Status; got != "save_unsupported" {
		t.Fatalf("unsaveable platform was admitted: %s", got)
	}
}

func stageNames(d batchreport.Device) []string {
	names := []string{}
	for _, s := range d.Stages {
		names = append(names, s.Name)
	}
	return names
}

func stageStatuses(d batchreport.Device) string {
	parts := []string{}
	for _, s := range d.Stages {
		parts = append(parts, s.Name+":"+s.Status)
	}
	return strings.Join(parts, ",")
}

func TestExecSavesReadOnlyOutputsAndRefusesWrites(t *testing.T) {
	rows, runtime := deployRuntime(t, []inventory.Device{{IP: "192.0.2.1", Vendor: "cisco", OS: "ios", Name: "core"}})
	fake := &fakeSwitch{received: map[string][]string{}}
	var opened atomic.Int32
	runtime.OpenDevice = fake.opener(t, &opened)
	directory := t.TempDir()
	result, err := (&workflow.Runner{}).Exec(t.Context(), runtime, rows, workflow.ExecOptions{Commands: []string{"show running-config"}, Directory: directory, Policy: "selected"})
	if err != nil || !result.Success {
		t.Fatalf("exec failed: %v %+v", err, result.Report)
	}
	device := result.Report.Devices[0]
	if device.Outcome != "executed" || len(device.Artifacts.Outputs) != 1 {
		t.Fatalf("outputs: %+v", device)
	}
	body, err := os.ReadFile(device.Artifacts.Outputs[0].Path)
	if err != nil || string(body) != "### show running-config\nhostname sw\ninterface Gi0/1\n" {
		t.Fatalf("saved output %q %v", body, err)
	}
	if filepath.Base(device.Artifacts.Outputs[0].Path) != "core-192.0.2.1.txt" {
		t.Fatal(device.Artifacts.Outputs[0].Path)
	}

	opened.Store(0)
	result, err = (&workflow.Runner{}).Exec(t.Context(), runtime, rows, workflow.ExecOptions{Commands: []string{"show version", "configure terminal"}, Directory: t.TempDir(), Policy: "selected"})
	if err != nil || result.Success || opened.Load() != 0 || result.Report.Devices[0].Status != "not_read_only" {
		t.Fatalf("write command admitted: opened=%d %+v %v", opened.Load(), result.Report, err)
	}
}

func TestRemoteBackupExportsOnlyCapablePlatforms(t *testing.T) {
	rows, runtime := deployRuntime(t, []inventory.Device{{IP: "192.0.2.1", Vendor: "juniper", OS: "junos"}, {IP: "192.0.2.2", Vendor: "cisco", OS: "ios"}})
	var commands []string
	var opened atomic.Int32
	runtime.OpenDevice = func(_ context.Context, r fleet.Record, logger io.Writer, _ workflow.SessionObserver) (*connector.Device, error) {
		opened.Add(1)
		driver := connector.StaticDriver{Grammar: connector.Terminal{Name: r.Platform, LoginPrompt: mustPattern(t, `ops@mx>\s*\z`), CommandPrompt: mustPattern(t, `ops@mx>\s*\z`)}}
		return connector.New(driver, connector.ConnectionConfig{Host: r.Host, Username: "ops", Password: "device-secret", Logger: logger}, connector.WithTransportFactory(func(context.Context, connector.ConnectionConfig) (io.ReadWriteCloser, error) {
			a, b := net.Pipe()
			go func() {
				defer b.Close()
				_, _ = io.WriteString(b, "ops@mx>")
				line, err := bufio.NewReader(b).ReadString('\n')
				if err != nil {
					return
				}
				line = strings.TrimSpace(line)
				commands = append(commands, line)
				destination := strings.TrimPrefix(line, "show configuration | save ")
				_, _ = io.WriteString(b, line+"\r\nWrote 42 lines of output to '"+destination+"'\r\nops@mx>")
				_, _ = io.Copy(io.Discard, b)
			}()
			return a, nil
		}))
	}
	options := workflow.RemoteBackupOptions{RemoteOptions: transfer.RemoteOptions{Server: "192.0.2.9", Path: "backups", Username: "backup", Protocol: "scp", Password: "remote-secret"}, Directory: t.TempDir(), Policy: "selected"}
	result, err := (&workflow.Runner{}).RemoteBackup(t.Context(), runtime, rows, options)
	if err != nil || opened.Load() != 1 {
		t.Fatalf("opened=%d err=%v", opened.Load(), err)
	}
	juniper, cisco := result.Report.Devices[0], result.Report.Devices[1]
	if juniper.Status != batchreport.StatusSucceeded || juniper.Outcome != "exported" || !juniper.Artifacts.Remote.Reported || cisco.Status != "unsupported_operation" {
		t.Fatalf("remote backup: %+v %+v", juniper, cisco)
	}
	if len(commands) != 1 || !strings.HasPrefix(commands[0], "show configuration | save scp://backup@192.0.2.9/backups/192.0.2.1-") || !strings.HasSuffix(commands[0], ".conf") {
		t.Fatalf("command: %q", commands)
	}
	data, _ := json.Marshal(result.Report)
	if strings.Contains(string(data), "remote-secret") {
		t.Fatal("password in report")
	}
	if _, err = (&workflow.Runner{}).RemoteBackup(t.Context(), runtime, rows, workflow.RemoteBackupOptions{RemoteOptions: options.RemoteOptions, Policy: "verified", Directory: t.TempDir()}); !errors.Is(err, workflow.ErrInvalidRequest) {
		t.Fatalf("verified policy accepted: %v", err)
	}
}

func TestDeploySnapshotsConfigurationAroundTheChange(t *testing.T) {
	rows, runtime := deployRuntime(t, []inventory.Device{{IP: "192.0.2.1", Vendor: "cisco", OS: "ios", Name: "core"}})
	fake := &fakeSwitch{saveReply: "[OK]", received: map[string][]string{}}
	var opened atomic.Int32
	runtime.OpenDevice = fake.opener(t, &opened)
	script := parseScript(t, "vlan 10\nname users\n")
	result, err := (&workflow.Runner{}).Deploy(t.Context(), runtime, rows, workflow.DeployOptions{Scripts: workflow.DeployScripts{Default: &script}, Save: true, Snapshot: true, Directory: t.TempDir(), Policy: "selected"})
	if err != nil || !result.Success {
		t.Fatalf("deploy failed: %v %+v", err, result.Report)
	}
	device := result.Report.Devices[0]
	change := device.Artifacts.Change
	if change == nil || change.Before == nil || change.After == nil || !change.Compared || !change.Changed || change.Added != 2 || change.Removed != 0 {
		t.Fatalf("change evidence: %+v", change)
	}
	if device.Artifacts.Backup == nil || device.Artifacts.Backup.Path != change.After.Path || change.Before.SHA256 == change.After.SHA256 {
		t.Fatalf("after snapshot is not the backup artifact: %+v %+v", device.Artifacts.Backup, change)
	}
	before, err := os.ReadFile(change.Before.Path)
	if err != nil || strings.Contains(string(before), "vlan 10") || filepath.Base(filepath.Dir(change.Before.Path)) != "before" {
		t.Fatalf("before snapshot: %q %v", before, err)
	}
	diff, err := os.ReadFile(change.DiffFile)
	if err != nil || !strings.Contains(string(diff), "+vlan 10\n+name users\n") || strings.Contains(string(diff), "\n-") && !strings.HasPrefix(string(diff), "--- ") {
		t.Fatalf("diff: %q %v", diff, err)
	}
}

func TestDeployWithoutSnapshotSendsOnlyTheScript(t *testing.T) {
	rows, runtime := deployRuntime(t, []inventory.Device{{IP: "192.0.2.1", Vendor: "cisco", OS: "ios"}})
	fake := &fakeSwitch{saveReply: "[OK]", received: map[string][]string{}}
	var opened atomic.Int32
	runtime.OpenDevice = fake.opener(t, &opened)
	script := parseScript(t, "vlan 10\n")
	result, err := (&workflow.Runner{}).Deploy(t.Context(), runtime, rows, workflow.DeployOptions{Scripts: workflow.DeployScripts{Default: &script}, Directory: t.TempDir(), Policy: "selected"})
	if err != nil || !result.Success || result.Report.Devices[0].Artifacts.Change != nil {
		t.Fatalf("deploy without snapshot: %v %+v", err, result.Report)
	}
	if lines := fake.lines("192.0.2.1"); strings.Join(lines, "|") != "vlan 10" {
		t.Fatalf("unexpected device input: %q", lines)
	}
}

func TestDeployStopsBeforeWritingWhenTheBeforeSnapshotFails(t *testing.T) {
	rows, runtime := deployRuntime(t, []inventory.Device{{IP: "192.0.2.1", Vendor: "cisco", OS: "ios"}})
	fake := &fakeSwitch{saveReply: "[OK]", failConfig: true, received: map[string][]string{}}
	var opened atomic.Int32
	runtime.OpenDevice = fake.opener(t, &opened)
	script := parseScript(t, "vlan 10\n")
	result, err := (&workflow.Runner{}).Deploy(t.Context(), runtime, rows, workflow.DeployOptions{Scripts: workflow.DeployScripts{Default: &script}, Save: true, Snapshot: true, Directory: t.TempDir(), Policy: "selected"})
	if err != nil || result.Success {
		t.Fatalf("failed snapshot reported success: %v", err)
	}
	device := result.Report.Devices[0]
	if device.Status != batchreport.StatusFailed || device.FailedStage != "snapshot_before" || device.Artifacts.Script != nil {
		t.Fatalf("a failed before-snapshot must be a clean failure: %+v", device)
	}
	if lines := fake.lines("192.0.2.1"); strings.Join(lines, "|") != "show running-config" {
		t.Fatalf("the script was sent without a before-snapshot: %q", lines)
	}
}

func TestRejectedDeployKeepsTheBeforeSnapshot(t *testing.T) {
	rows, runtime := deployRuntime(t, []inventory.Device{{IP: "192.0.2.1", Vendor: "cisco", OS: "ios"}})
	fake := &fakeSwitch{saveReply: "[OK]", received: map[string][]string{}}
	var opened atomic.Int32
	runtime.OpenDevice = fake.opener(t, &opened)
	script := parseScript(t, "vlan 20\nbad command\n")
	result, err := (&workflow.Runner{}).Deploy(t.Context(), runtime, rows, workflow.DeployOptions{Scripts: workflow.DeployScripts{Default: &script}, Snapshot: true, Directory: t.TempDir(), Policy: "selected"})
	if err != nil || result.Success {
		t.Fatalf("rejected deploy reported success: %v", err)
	}
	device := result.Report.Devices[0]
	change := device.Artifacts.Change
	if device.Status != batchreport.StatusPartial || change == nil || change.Before == nil || change.After != nil || change.Compared {
		t.Fatalf("rollback reference lost: %+v %+v", device, change)
	}
	if _, err = os.Stat(change.Before.Path); err != nil {
		t.Fatalf("before snapshot missing after a rejection: %v", err)
	}
}

// candidateDevice opens the registered platform driver against a peer that
// answers each expected line in order and records what it received.
func candidateDevice(t *testing.T, runtime workflow.Runtime, login string, replies map[string]string, received *[]string) workflow.DeviceOpener {
	t.Helper()
	var mu sync.Mutex
	return func(_ context.Context, r fleet.Record, logger io.Writer, _ workflow.SessionObserver) (*connector.Device, error) {
		driver, err := runtime.Registry.Lookup(r.Platform)
		if err != nil {
			return nil, err
		}
		config := connector.ConnectionConfig{Host: r.Host, Username: "admin", Password: "secret", Logger: logger}
		return connector.New(driver, config, connector.WithTransportFactory(func(context.Context, connector.ConnectionConfig) (io.ReadWriteCloser, error) {
			a, b := net.Pipe()
			go func() {
				defer b.Close()
				_, _ = io.WriteString(b, login)
				reader := bufio.NewReader(b)
				for {
					line, err := reader.ReadString('\n')
					if err != nil {
						return
					}
					line = strings.TrimRight(line, "\r\n")
					mu.Lock()
					*received = append(*received, line)
					mu.Unlock()
					if _, err = io.WriteString(b, replies[line]); err != nil {
						return
					}
				}
			}()
			return a, nil
		}))
	}
}

func TestDeployCommitsOnCandidatePlatforms(t *testing.T) {
	const config, operational = "\r\n[edit]\r\nadmin@mx# ", "admin@mx> "
	rows, runtime := deployRuntime(t, []inventory.Device{{IP: "192.0.2.1", Vendor: "juniper", OS: "junos"}, {IP: "192.0.2.2", Vendor: "cisco", OS: "ios"}})
	var received []string
	runtime.OpenDevice = candidateDevice(t, runtime, operational, map[string]string{
		"configure exclusive":             "Entering configuration mode\r\n" + config,
		"set system ntp server 192.0.2.5": config,
		"commit check":                    "configuration check succeeds\r\n" + config,
		"commit confirmed 5":              "commit confirmed will be automatically rolled back in 5 minutes unless confirmed\r\ncommit complete\r\n" + config,
		"commit":                          "commit complete\r\n" + config,
		"exit":                            "Exiting configuration mode\r\n\r\n" + operational,
	}, &received)
	script := parseScript(t, "set system ntp server 192.0.2.5\n")
	result, err := (&workflow.Runner{}).Deploy(t.Context(), runtime, rows, workflow.DeployOptions{Scripts: workflow.DeployScripts{Default: &script}, Save: true, CommitConfirm: 5, Directory: t.TempDir(), Policy: "selected"})
	// A device skipped for lacking a confirmed commit is not an intentional
	// skip, so the batch stays incomplete and the operator has to look.
	if err != nil || result.Success || result.Report.Counts[batchreport.StatusSucceeded] != 1 {
		t.Fatalf("deploy: %v %+v", err, result.Report)
	}
	junos, ios := result.Report.Devices[0], result.Report.Devices[1]
	if ios.Status != batchreport.StatusConfirmUnsupported {
		t.Fatalf("a platform without confirmed commit was admitted: %s", ios.Status)
	}
	if junos.Outcome != batchreport.OutcomeDeployed || junos.Artifacts.Commit == nil || !junos.Artifacts.Commit.Confirmed || junos.Artifacts.Commit.ConfirmMinutes != 5 || junos.Artifacts.Save != nil {
		t.Fatalf("commit evidence: %+v", junos)
	}
	if s := junos.Artifacts.Script; s.Commands != 1 || s.Accepted != 1 {
		t.Fatalf("wrapping commands were counted as script commands: %+v", s)
	}
	if got := strings.Join(received, "|"); got != "configure exclusive|set system ntp server 192.0.2.5|commit check|commit confirmed 5|commit|exit" {
		t.Fatalf("device input: %q", got)
	}
}

func TestDeployReportsADirtySharedCandidate(t *testing.T) {
	const config, operational = "\r\n[edit]\r\nadmin@fw# ", "admin@fw> "
	rows, runtime := deployRuntime(t, []inventory.Device{{IP: "192.0.2.1", Vendor: "Palo Alto Networks", OS: "PAN-OS"}})
	var received []string
	runtime.OpenDevice = candidateDevice(t, runtime, operational, map[string]string{
		"configure":                          "Entering configuration mode" + config,
		"set deviceconfig system hostname a": config,
		"set bogus":                          "Invalid syntax.\r\n" + config,
	}, &received)
	script := parseScript(t, "set deviceconfig system hostname a\nset bogus\n")
	result, err := (&workflow.Runner{}).Deploy(t.Context(), runtime, rows, workflow.DeployOptions{Scripts: workflow.DeployScripts{Default: &script}, Directory: t.TempDir(), Policy: "selected"})
	if err != nil || result.Success {
		t.Fatalf("rejected candidate reported success: %v", err)
	}
	device := result.Report.Devices[0]
	if device.Status != batchreport.StatusPartial || device.Outcome != batchreport.OutcomeCandidateDirty || device.Artifacts.Commit.Confirmed || device.Artifacts.Script.FailedLine != 2 {
		t.Fatalf("dirty candidate evidence: %+v %+v", device, device.Artifacts.Script)
	}
	if got := strings.Join(received, "|"); got != "configure|set deviceconfig system hostname a|set bogus" {
		t.Fatalf("commit or revert was sent after a rejection: %q", got)
	}
}

func TestFactsReportsInventoryMismatchesWithReadOnlyCommands(t *testing.T) {
	rows, runtime := deployRuntime(t, []inventory.Device{
		{IP: "192.0.2.1", Vendor: "cisco", OS: "ios", Model: "Cisco WS-C3750G-24TS", Serial: "FOC0000WRONG", OSVersion: "12.2(55)SE9"},
		{IP: "192.0.2.2", Vendor: "topsec"},
	})
	var received []string
	version := "\r\nCisco IOS Software, C3750 Software (C3750-IPSERVICESK9-M), Version 12.2(55)SE9, RELEASE SOFTWARE (fc1)\r\ncore-sw uptime is 1 week, 2 days\r\ncisco WS-C3750G-24TS (PowerPC405) processor (revision H0) with 131072K bytes of memory.\r\nProcessor board ID FOC1234X5YZ\r\ncore-sw#"
	runtime.OpenDevice = candidateDevice(t, runtime, "core-sw#", map[string]string{"show version": version}, &received)
	result, err := (&workflow.Runner{}).Facts(t.Context(), runtime, rows, workflow.FactsOptions{Directory: t.TempDir(), Policy: "selected"})
	if err != nil {
		t.Fatal(err)
	}
	device, unsupported := result.Report.Devices[0], result.Report.Devices[1]
	if unsupported.Status != batchreport.StatusUnsupportedOperation {
		t.Fatalf("a platform without fact commands was admitted: %s", unsupported.Status)
	}
	found := device.Artifacts.Facts
	if found == nil || found.Model != "WS-C3750G-24TS" || found.Serial != "FOC1234X5YZ" || found.OSVersion != "12.2(55)SE9" || found.Hostname != "core-sw" {
		t.Fatalf("facts: %+v (device %+v)", found, device)
	}
	if strings.Join(found.Mismatches, ",") != "serial" || device.Outcome != batchreport.OutcomeMismatch || device.Status != batchreport.StatusPartial {
		t.Fatalf("mismatch evidence: %+v status=%s outcome=%s", found.Mismatches, device.Status, device.Outcome)
	}
	if got := strings.Join(received, "|"); got != "show version" {
		t.Fatalf("device input: %q", got)
	}
}

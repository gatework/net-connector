package connector_test

import (
	"context"
	"net/netip"
	"testing"
	"time"

	"go.uber.org/goleak"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/connectortest"
	"github.com/gatework/net-connector/driver"
	"github.com/gatework/net-connector/vendors"
	"github.com/gatework/netops/change"
	"github.com/gatework/netops/credential"
	"github.com/gatework/netops/device"
	"github.com/gatework/netops/failure"
	"github.com/gatework/netops/ops"
	"github.com/gatework/netops/secret"
)

func TestMain(m *testing.M) { goleak.VerifyTestMain(m) }

type step = connectortest.Step

var (
	send  = connectortest.Send
	reply = connectortest.Reply
)

func dialer(t *testing.T, scripts ...[]step) *connector.Dialer {
	t.Helper()
	d, err := connector.NewDialer(connector.Options{
		Registry:    vendors.Builtin(),
		Credentials: credential.Static{Username: "admin", Password: secret.New("s3cret"), EnablePassword: secret.New("en4ble")},
		Transport:   connectortest.NewDialer(t, scripts...),
		Timeout:     2 * time.Second,
	})
	if err != nil {
		t.Fatal(err)
	}
	return d
}

func dev(platform string) device.Device {
	return device.Device{ID: "d1", Mgmt: netip.MustParseAddr("192.0.2.10"), Platform: platform}.Normalize()
}

func open(t *testing.T, platform string, script []step, fn func(context.Context, *connector.Session) error) error {
	t.Helper()
	opErr, closeErr := dialer(t, script).Open(t.Context(), dev(platform), fn)
	if closeErr != nil {
		t.Errorf("close: %v", closeErr)
	}
	return opErr
}

func code(err error) failure.Code { return failure.Primary(err) }

func TestH3C(t *testing.T) {
	t.Parallel()
	script := []step{
		send("\r\n******************************************************************************\r\n* Copyright (c) 2004-2026 New H3C Technologies Co., Ltd. All rights reserved.*\r\n******************************************************************************\r\n\r\n<core-1>"),
		reply("screen-length disable\n", "screen-length disable\r\n<core-1>"),
		reply("display current-configuration\n", "display current-configuration\r\n#\r\n version 7.1.070, Release 6728P22\r\n#\r\n sysname core-1\r\n#\r\nreturn\r\n<core-1>"),
		reply("system-view\n", "system-view\r\nSystem View: return to User View with Ctrl+Z.\r\n[core-1]"),
		reply("interface GigabitEthernet1/0/1\n", "interface GigabitEthernet1/0/1\r\n[core-1-GigabitEthernet1/0/1]"),
		reply("descr To_core-2\n", "descr To_core-2\r\n      ^\r\n % Unrecognized command found at '^' position.\r\n[core-1-GigabitEthernet1/0/1]"),
		reply("description To_core-2_Gi1/0/1\n", "description To_core-2_Gi1/0/1\r\n[core-1-GigabitEthernet1/0/1]"),
		reply("return\n", "return\r\n<core-1>"),
		reply("save force\n", "save force\r\nValidating file. Please wait.........\r\nSaved the current configuration to mainboard device successfully.\r\n<core-1>"),
		reply("tftp 192.0.2.9 put startup.cfg core-1.cfg\n", "tftp 192.0.2.9 put startup.cfg core-1.cfg\r\n  % Total    % Received % Xferd  Average Speed   Time    Time     Time  Current\r\n100  9876    0     0  100  9876      0   9876 --:--:-- --:--:-- --:--:--  9876\r\nTFTP: 9876 bytes sent in 1 second(s).\r\nFile uploaded successfully.\r\n<core-1>"),
	}
	err := open(t, "h3c", script, func(ctx context.Context, s *connector.Session) error {
		if s.Host() != "core-1" {
			t.Errorf("host = %q", s.Host())
		}
		cfg, err := s.Config(ctx)
		if err != nil || cfg != "#\n version 7.1.070, Release 6728P22\n#\n sysname core-1\n#\nreturn" {
			t.Errorf("config %q %v", cfg, err)
		}
		for _, c := range []string{"system-view", "interface GigabitEthernet1/0/1"} {
			if err := s.Write(ctx, change.Command{Text: c}); err != nil {
				t.Fatalf("%s: %v", c, err)
			}
		}
		if err := s.Write(ctx, change.Command{Text: "descr To_core-2"}); code(err) != failure.CodeRejected || failure.Reason(err) != "invalid_input" {
			t.Errorf("rejected write: %v", err)
		}
		for _, c := range []string{"description To_core-2_Gi1/0/1", "return"} {
			if err := s.Write(ctx, change.Command{Text: c}); err != nil {
				t.Fatalf("%s: %v", c, err)
			}
		}
		if err := s.Save(ctx); err != nil {
			t.Errorf("save: %v", err)
		}
		rec, err := s.Export(ctx, driver.Export{Server: "192.0.2.9", File: "core-1.cfg"})
		if err != nil || rec.Values["bytes"] != "9876" {
			t.Errorf("export: %+v %v", rec, err)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestCiscoIOSEnableAndExport(t *testing.T) {
	t.Parallel()
	script := []step{
		send("\r\nUser Access Verification\r\n\r\nsw1>"),
		reply("enable\n", "enable\r\nPassword: "),
		reply("en4ble\n", "\r\nsw1#"),
		reply("terminal length 0\n", "terminal length 0\r\nsw1#"),
		reply("terminal width 511\n", "terminal width 511\r\nsw1#"),
		reply("copy running-config tftp:\n", "copy running-config tftp:\r\nAddress or name of remote host []? "),
		reply("192.0.2.9\n", "\r\nDestination filename [sw1-confg]? "),
		reply("sw1.cfg\n", "\r\n!!\r\n4123 bytes copied in 0.512 secs (8053 bytes/sec)\r\nsw1#"),
		reply("copy running-config startup-config\n", "copy running-config startup-config\r\nDestination filename [startup-config]? "),
		reply("\n", "\r\nBuilding configuration...\r\n[OK]\r\nsw1#"),
	}
	err := open(t, "cisco_ios", script, func(ctx context.Context, s *connector.Session) error {
		rec, err := s.Export(ctx, driver.Export{Server: "192.0.2.9", File: "sw1.cfg"})
		if err != nil || rec.Values["bytes"] != "4123" {
			t.Errorf("export: %+v %v", rec, err)
		}
		return s.Save(ctx)
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestNXOSCheckpoint(t *testing.T) {
	t.Parallel()
	script := []step{
		send("\r\nCisco Nexus Operating System (NX-OS) Software\r\nleaf-1# "),
		reply("terminal length 0\n", "terminal length 0\r\nleaf-1# "),
		reply("terminal width 511\n", "terminal width 511\r\nleaf-1# "),
		reply("checkpoint pre-change\n", "checkpoint pre-change\r\n.......Done\r\nleaf-1# "),
		reply("rollback running-config checkpoint pre-change atomic\n", "rollback running-config checkpoint pre-change atomic\r\nNote: Applying config parallelly may fail Rollback verification\r\nCollecting Running-Config\r\n#Generating Rollback Patch\r\nRollback completed successfully.\r\n\r\nleaf-1# "),
	}
	err := open(t, "cisco_nxos", script, func(ctx context.Context, s *connector.Session) error {
		if !s.CanCheckpoint() {
			t.Fatal("nx-os declares checkpoints")
		}
		if err := s.Checkpoint(ctx, "pre-change"); err != nil {
			return err
		}
		return s.Rollback(ctx, "pre-change")
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestHuaweiSaveAnswersOnlyItsQuestion(t *testing.T) {
	t.Parallel()
	script := []step{
		send("\r\nInfo: The max number of VTY users is 10.\r\n<HUAWEI>"),
		reply("screen-length 0 temporary\n", "screen-length 0 temporary\r\nInfo: The configuration takes effect on the current user terminal interface only.\r\n<HUAWEI>"),
		reply("save\n", "save\r\nThe current configuration will be written to the device.\r\nAre you sure to continue?[Y/N]"),
		reply("Y\n", "Y\r\nNow saving the current configuration to the slot 0.\r\nInfo: Save the configuration successfully.\r\n<HUAWEI>"),
		reply("reboot\n", "reboot\r\nInfo: The system is now comparing the configuration, please wait.\r\nSystem will reboot! Continue ? [y/n]:"),
		reply("\x03", "\r\n<HUAWEI>"),
	}
	err := open(t, "huawei", script, func(ctx context.Context, s *connector.Session) error {
		if err := s.Save(ctx); err != nil {
			return err
		}
		// The same Y/N shape outside the save procedure is never answered.
		if err := s.Write(ctx, change.Command{Text: "reboot"}); code(err) != failure.CodeInteraction {
			t.Errorf("reboot: %v", err)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestJunosCommit(t *testing.T) {
	t.Parallel()
	script := []step{
		send("--- JUNOS 21.4R3 built 2026-01-01\r\nadmin@mx1> "),
		reply("set cli screen-length 0\n", "set cli screen-length 0\r\nScreen length set to 0\r\n\r\nadmin@mx1> "),
		reply("set cli screen-width 0\n", "set cli screen-width 0\r\nScreen width set to 0\r\n\r\nadmin@mx1> "),
		reply("configure exclusive\n", "configure exclusive\r\nwarning: uncommitted changes will be discarded on exit\r\nEntering configuration mode\r\n\r\n[edit]\r\nadmin@mx1# "),
		reply("set interfaces ge-0/0/1 description uplink\n", "set interfaces ge-0/0/1 description uplink\r\n\r\n[edit]\r\nadmin@mx1# "),
		reply("commit check\n", "commit check\r\nconfiguration check succeeds\r\n\r\n[edit]\r\nadmin@mx1# "),
		reply("commit\n", "commit\r\ncommit complete\r\n\r\n[edit]\r\nadmin@mx1# "),
		reply("exit configuration-mode\n", "exit configuration-mode\r\nExiting configuration mode\r\n\r\nadmin@mx1> "),
	}
	err := open(t, "juniper", script, func(ctx context.Context, s *connector.Session) error {
		rec, err := s.Commit(ctx, []string{"set interfaces ge-0/0/1 description uplink"}, driver.CommitOptions{})
		if err == nil && rec.Evidence != "commit_ok" {
			t.Errorf("evidence %q", rec.Evidence)
		}
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestJunosCommitCheckFailureLeavesCandidate(t *testing.T) {
	t.Parallel()
	script := []step{
		send("admin@mx1> "),
		reply("set cli screen-length 0\n", "\r\nadmin@mx1> "),
		reply("set cli screen-width 0\n", "\r\nadmin@mx1> "),
		reply("configure exclusive\n", "configure exclusive\r\nEntering configuration mode\r\n\r\n[edit]\r\nadmin@mx1# "),
		reply("set protocols ospf area 0 interface ge-0/0/9\n", "\r\n[edit]\r\nadmin@mx1# "),
		reply("commit check\n", "commit check\r\n[edit protocols ospf]\r\n  'area 0.0.0.0'\r\n    interface ge-0/0/9: interface not found\r\nerror: configuration check-out failed\r\n\r\n[edit]\r\nadmin@mx1# "),
		reply("exit configuration-mode\n", "exit configuration-mode\r\nThe configuration has been changed but not committed\r\nExit with uncommitted changes? [yes,no] (yes) "),
		reply("yes\n", "\r\nExiting configuration mode\r\n\r\nadmin@mx1> "),
	}
	err := open(t, "juniper", script, func(ctx context.Context, s *connector.Session) error {
		_, err := s.Commit(ctx, []string{"set protocols ospf area 0 interface ge-0/0/9"}, driver.CommitOptions{})
		return err
	})
	if code(err) != failure.CodeRejected || failure.Reason(err) != "commit_check_failed" {
		t.Fatalf("err = %v", err)
	}
}

func TestPANOSPassiveRefusesWrites(t *testing.T) {
	t.Parallel()
	script := []step{
		send("Do you acknowledge the terms of use? (Enter yes/no) "),
		reply("yes\n", "\r\nadmin@fw-1(passive)> "),
		reply("set cli pager off\n", "set cli pager off\r\n\r\nadmin@fw-1(passive)> "),
	}
	err := open(t, "palo_alto", script, func(ctx context.Context, s *connector.Session) error {
		if st := s.State(); st.Role != "passive" || st.Writable {
			t.Errorf("state = %+v", st)
		}
		if err := s.Write(ctx, change.Command{Text: "set deviceconfig system hostname x"}); code(err) != failure.CodeUnsupported {
			t.Errorf("write on passive: %v", err)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestHillstoneSave(t *testing.T) {
	t.Parallel()
	script := []step{
		send("\r\nSG-6000(M)# "),
		reply("terminal length 0\n", "terminal length 0\r\nSG-6000(M)# "),
		reply("save all\n", "save all\r\nSave configuration, are you sure? [y]/n: "),
		reply("y\n", "y\r\nSaving configuration is finished\r\nSG-6000(M)# "),
	}
	err := open(t, "hillstone", script, func(ctx context.Context, s *connector.Session) error {
		if st := s.State(); st.Role != "master" || !st.Writable {
			t.Errorf("state = %+v", st)
		}
		return s.Save(ctx)
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestFortiGateDisclaimerAndPager(t *testing.T) {
	t.Parallel()
	script := []step{
		send("WARNING: authorised use only\r\n(Press 'a' to accept):"),
		reply("a", "\r\nFGT-1 # "),
		reply("show full-configuration\n", "show full-configuration\r\nconfig system global\r\n    set hostname \"FGT-1\"\r\n--More-- "),
		reply(" ", "\r\nend\r\n\r\nFGT-1 # "),
	}
	err := open(t, "fortinet", script, func(ctx context.Context, s *connector.Session) error {
		cfg, err := s.Config(ctx)
		if err == nil && cfg != "config system global\n    set hostname \"FGT-1\"\nend" {
			t.Errorf("config = %q", cfg)
		}
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestRadwareStandby(t *testing.T) {
	t.Parallel()
	script := []step{
		send("Alteon Application Switch\r\nHA State: STANDBY\r\nConfirm seeing above note [y]: "),
		reply("y\n", "\r\n>> Main# "),
	}
	err := open(t, "radware", script, func(_ context.Context, s *connector.Session) error {
		if st := s.State(); st.Role != "standby" || st.Writable {
			t.Errorf("state = %+v", st)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestCollect(t *testing.T) {
	t.Parallel()
	script := []step{
		send("<ac-1>"),
		reply("screen-length disable\n", "screen-length disable\r\n<ac-1>"),
		reply("display wlan client\n", "display wlan client\r\nTotal number of clients: 0\r\n<ac-1>"),
		reply("display wlan bogus\n", "display wlan bogus\r\n            ^\r\n % Unrecognized command found at '^' position.\r\n<ac-1>"),
	}
	d := dialer(t, script)
	var c ops.Session
	opErr, closeErr := d.Port().Open(t.Context(), dev("h3c_wireless"), func(ctx context.Context, s ops.Session) error {
		c = s
		got, err := s.Collect(ctx, []string{"display wlan client", "display wlan bogus"})
		if err != nil {
			return err
		}
		if len(got.Outputs) != 2 || !got.Outputs[0].OK() || got.Outputs[1].Failure != failure.CodeRejected || got.Prompt != "<ac-1>" {
			t.Errorf("capture = %+v", got)
		}
		lines, _ := got.Outputs[0].Body(ctx, nil)
		if len(lines) != 1 || lines[0].Text != "Total number of clients: 0" {
			t.Errorf("body = %+v", lines)
		}
		return nil
	})
	if opErr != nil || closeErr != nil || c == nil {
		t.Fatal(opErr, closeErr)
	}
}

func TestDialFailures(t *testing.T) {
	t.Parallel()
	d := dialer(t)
	if _, err := d.Dial(t.Context(), dev("acme")); code(err) != failure.CodeUnsupported {
		t.Errorf("unknown platform: %v", err)
	}
	nd, _ := connector.NewDialer(connector.Options{Registry: vendors.Builtin(), Credentials: credential.Chain{}, Transport: connectortest.NewDialer(t)})
	if _, err := nd.Dial(t.Context(), dev("h3c")); code(err) != failure.CodeNoCreds {
		t.Errorf("no credentials: %v", err)
	}
	if nd.CanConnect(t.Context(), dev("h3c")) {
		t.Error("CanConnect without credentials")
	}
}

func TestReadOnly(t *testing.T) {
	t.Parallel()
	nx, _ := vendors.Builtin().Lookup("cisco_nxos")
	if !connector.ReadOnly(nx, "show run | include hostname") || connector.ReadOnly(nx, "copy run start") {
		t.Error("ReadOnly")
	}
}

// panConfig is the guarded PAN-OS read; before and after are the bodies of
// the two "show config diff" commands.
func panConfig(before, after string) []step {
	return []step{
		send("admin@fw> "),
		reply("set cli pager off\n", "set cli pager off\r\n\r\nadmin@fw> "),
		reply("set cli config-output-format set\n", "set cli config-output-format set\r\n\r\nadmin@fw> "),
		reply("show config diff\n", "show config diff\r\n"+before+"\r\nadmin@fw> "),
		reply("configure\n", "configure\r\nEntering configuration mode\r\n[edit]\r\nadmin@fw# "),
		reply("show\n", "show\r\nset deviceconfig system hostname fw\r\nset rulebase security rules allow-dns action allow\r\n[edit]\r\nadmin@fw# "),
		reply("exit\n", "exit\r\nExiting configuration mode\r\nadmin@fw> "),
		reply("show config diff\n", "show config diff\r\n"+after+"\r\nadmin@fw> "),
	}
}

func TestPANOSConfigRead(t *testing.T) {
	t.Parallel()
	err := open(t, "palo_alto", panConfig("", ""), func(ctx context.Context, s *connector.Session) error {
		cfg, err := s.Config(ctx)
		if err == nil && cfg != "set deviceconfig system hostname fw\nset rulebase security rules allow-dns action allow" {
			t.Errorf("config = %q", cfg)
		}
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestPANOSConfigRefusesUncommittedCandidate(t *testing.T) {
	t.Parallel()
	err := open(t, "palo_alto", panConfig("+ set rulebase security rules temp action allow", ""), func(ctx context.Context, s *connector.Session) error {
		_, err := s.Config(ctx)
		return err
	})
	if code(err) != failure.CodeIncomplete {
		t.Fatalf("err = %v", err)
	}
}

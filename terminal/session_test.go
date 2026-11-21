package terminal_test

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"go.uber.org/goleak"

	"github.com/gatework/expect/record"
	"github.com/gatework/net-connector/connectortest"
	"github.com/gatework/net-connector/terminal"
	"github.com/gatework/netops/failure"
	"github.com/gatework/netops/secret"
)

func TestMain(m *testing.M) { goleak.VerifyTestMain(m) }

// grammar is a small IOS-like dialect for engine tests.
func grammar() terminal.Grammar {
	return terminal.Grammar{
		Login: terminal.Login{
			Banner:   []terminal.Rule{{Name: "press_return", Pattern: `Press RETURN to get started\.?`, Reply: terminal.Enter()}},
			Username: []string{`(?i)username:`},
			Password: []string{`(?i)password:`},
			Failed:   []terminal.Signature{terminal.Sig(terminal.ReasonLoginFailed, `(?i)% ?(?:Login invalid|Authentication failed)`)},
			Locked:   []terminal.Signature{terminal.Sig(terminal.ReasonLocked, `(?i)locked`)},
			Expired:  []terminal.Rule{{Name: "password_change", Pattern: `(?i)change now\? ?\[Y/N\]:?`, Reply: terminal.Answer("N")}},
			Timeout:  time.Second,
		},
		Prompts: []terminal.Prompt{
			{Mode: terminal.ModeConfigSub, Expr: terminal.Host + `\(config-[^)]+\)#`},
			{Mode: terminal.ModeConfig, Expr: terminal.Host + `\(config\)#`},
			{Mode: terminal.ModePrivileged, Expr: terminal.Host + `#`},
			{Mode: terminal.ModeUser, Expr: terminal.Host + `>`},
		},
		Privilege:   &terminal.Privilege{Command: "enable", From: terminal.ModeUser, Password: []string{`(?i)password:`}, Failed: []terminal.Signature{terminal.Sig(terminal.ReasonEnableFailed, `% Access denied|% Bad secrets`)}},
		Config:      terminal.ConfigMode{Enter: "configure terminal", Leave: "end"},
		Preparation: []string{"terminal length 0"},
		Pager:       []terminal.Rule{{Name: "more", Pattern: ` ?--More-- ?`, Reply: terminal.Key(" "), Limit: -1}},
		Errors: []terminal.Signature{
			terminal.Sig(terminal.ReasonInvalidInput, `^% Invalid input detected`),
			terminal.Sig(terminal.ReasonIncomplete, `^% Incomplete command`),
		},
		Warnings: []terminal.Signature{terminal.Sig(terminal.ReasonWarning, `^Warning:`)},
		Async:    []string{`^\*?\w{3}\s+\d+ [\d:.]+: %\w+-\d-\w+:`},
		Questions: []string{
			`\[confirm\]`, `\[[Yy](?:es)?/[Nn]o?\]\??:?`, `\?\s*\[[^\]]*\]\??`,
		},
		Rules: []terminal.Rule{
			{Name: "dest_filename", Pattern: `Destination filename \[[^\]]+\]\?`, Reply: terminal.Enter()},
			{Name: "reload", Pattern: `Proceed with reload\? \[confirm\]`, Reply: terminal.Enter(), Risk: terminal.RiskDisruptive},
		},
	}
}

func creds() terminal.Credentials {
	return terminal.Credentials{Username: "admin", Password: secret.New("s3cret"), Enable: secret.New("en4ble")}
}

func session(t *testing.T, script ...connectortest.Step) (*terminal.Session, *connectortest.Device) {
	t.Helper()
	stream, dev := connectortest.Start(t, script...)
	s, err := terminal.New(stream, grammar(), creds(), terminal.Options{Timeout: 2 * time.Second, Recorder: record.Disabled()})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s, dev
}

// loggedIn is the dialogue up to a prepared privileged session on sw1.
var loggedIn = []connectortest.Step{
	connectortest.Send("\r\nPress RETURN to get started."),
	connectortest.Reply("\n", "\r\nUser Access Verification\r\n\r\nUsername: "),
	connectortest.Reply("admin\n", "Password: "),
	connectortest.Reply("s3cret\n", "\r\nsw1>"),
	connectortest.Reply("enable\n", "enable\r\nPassword: "),
	connectortest.Reply("en4ble\n", "\r\nsw1#"),
	connectortest.Reply("terminal length 0\n", "terminal length 0\r\nsw1#"),
}

func steps(more ...connectortest.Step) []connectortest.Step {
	return append(append([]connectortest.Step{}, loggedIn...), more...)
}

func code(err error) failure.Code { return failure.Primary(err) }

func TestLoginEscalatesAndPrepares(t *testing.T) {
	t.Parallel()
	s, _ := session(t, loggedIn...)
	if err := s.Login(t.Context()); err != nil {
		t.Fatal(err)
	}
	if s.Host() != "sw1" || s.Mode() != terminal.ModePrivileged || s.Prompt() != "sw1#" {
		t.Errorf("host %q mode %v prompt %q", s.Host(), s.Mode(), s.Prompt())
	}
}

func TestTranscriptRedactsFromFirstRead(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	recorder, err := record.New(record.Config{Enabled: true, Dir: dir, Formats: []record.Format{record.FormatLog}, Required: true})
	if err != nil {
		t.Fatal(err)
	}
	g := grammar()
	g.Redact = []string{`password cipher (\S+)`}
	script := steps()
	script[0].Send = "password cipher startup-secret\r\nlogin secret s3cret" + script[0].Send
	stream, _ := connectortest.Start(t, script...)
	s, err := terminal.New(stream, g, creds(), terminal.Options{Recorder: recorder, Label: "sw1"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	if err := s.Login(t.Context()); err != nil {
		t.Fatal(err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	files, err := filepath.Glob(filepath.Join(dir, "*", "sw1*.log"))
	if err != nil || len(files) != 1 {
		t.Fatalf("transcript files = %v, error = %v", files, err)
	}
	data, err := os.ReadFile(files[0])
	if err != nil {
		t.Fatal(err)
	}
	log := string(data)
	if !strings.Contains(log, "password cipher ") || !strings.Contains(log, "login secret ") {
		t.Fatal("transcript omitted the startup output")
	}
	for _, sensitive := range []string{"startup-secret", "s3cret", "en4ble"} {
		if strings.Contains(log, sensitive) {
			t.Fatal("transcript contains an unmasked secret")
		}
	}
}

func TestLoginSendsEachCredentialOnce(t *testing.T) {
	t.Parallel()
	s, _ := session(t,
		connectortest.Send("Username: "),
		connectortest.Reply("admin\n", "Password: "),
		connectortest.Reply("s3cret\n", "\r\n% Authentication failed\r\n\r\nUsername: "),
	)
	err := s.Login(t.Context())
	if code(err) != failure.CodeAuth || failure.Reason(err) != string(terminal.ReasonLoginFailed) {
		t.Fatalf("err = %v", err)
	}
}

func TestLoginLocked(t *testing.T) {
	t.Parallel()
	s, _ := session(t,
		connectortest.Send("Username: "),
		connectortest.Reply("admin\n", "Password: "),
		connectortest.Reply("s3cret\n", "\r\n% The user is locked\r\nUsername: "),
	)
	if err := s.Login(t.Context()); code(err) != failure.CodeLocked {
		t.Fatalf("err = %v", err)
	}
}

func TestLoginDeclinesPasswordChange(t *testing.T) {
	t.Parallel()
	s, _ := session(t,
		connectortest.Send("Username: "),
		connectortest.Reply("admin\n", "Password: "),
		connectortest.Reply("s3cret\n", "\r\nThe password needs to be changed. Change now? [Y/N]:"),
		connectortest.Reply("N\n", "\r\nsw1#"),
		connectortest.Reply("terminal length 0\n", "terminal length 0\r\nsw1#"),
	)
	if err := s.Login(t.Context()); err != nil {
		t.Fatal(err)
	}
}

func TestEnableFailure(t *testing.T) {
	t.Parallel()
	s, _ := session(t,
		connectortest.Send("Username: "),
		connectortest.Reply("admin\n", "Password: "),
		connectortest.Reply("s3cret\n", "\r\nsw1>"),
		connectortest.Reply("enable\n", "enable\r\nPassword: "),
		connectortest.Reply("en4ble\n", "\r\nPassword: "),
	)
	err := s.Login(t.Context())
	if code(err) != failure.CodeAuth || failure.Reason(err) != string(terminal.ReasonEnableFailed) {
		t.Fatalf("err = %v", err)
	}
}

func TestRunPagerAsyncAndRender(t *testing.T) {
	t.Parallel()
	s, _ := session(t, steps(
		connectortest.Reply("show version\n", "show version\r\nCisco IOS Software\r\n*Nov 19 08:00:01.123: %LINK-3-UPDOWN: Interface Gi1/0/1, changed state to up\r\n --More-- "),
		connectortest.Reply(" ", "\b\b\b\b\b\b\b\b\b\b          \b\b\b\b\b\b\b\b\b\bUptime is 3 weeks\r\nsw1#"),
	)...)
	if err := s.Login(t.Context()); err != nil {
		t.Fatal(err)
	}
	r, err := s.Run(t.Context(), terminal.Command{Text: "show version"})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := r.Text(), "Cisco IOS Software\nUptime is 3 weeks"; got != want {
		t.Errorf("body = %q, want %q", got, want)
	}
	if !r.OK() || len(r.Notices) != 1 || r.Notices[0].Reason != terminal.ReasonAsync {
		t.Errorf("response = %+v", r)
	}
}

func TestRunRejected(t *testing.T) {
	t.Parallel()
	s, _ := session(t, steps(
		connectortest.Reply("show vresion\n", "show vresion\r\n          ^\r\n% Invalid input detected at '^' marker.\r\n\r\nsw1#"),
		connectortest.Reply("show clock\n", "show clock\r\n08:00:00 UTC\r\nsw1#"),
	)...)
	if err := s.Login(t.Context()); err != nil {
		t.Fatal(err)
	}
	r, err := s.Run(t.Context(), terminal.Command{Text: "show vresion"})
	if err != nil || r.OK() || r.Reason() != terminal.ReasonInvalidInput || r.Issues[0].Line != 2 {
		t.Fatalf("rejected: %+v %v", r, err)
	}
	if r, err := s.Run(t.Context(), terminal.Command{Text: "show clock"}); err != nil || !r.OK() {
		t.Fatalf("session not preserved: %+v %v", r, err)
	}
}

func TestRunModeTransitions(t *testing.T) {
	t.Parallel()
	s, _ := session(t, steps(
		connectortest.Reply("configure terminal\n", "configure terminal\r\nsw1(config)#"),
		connectortest.Reply("interface Gi1/0/1\n", "interface Gi1/0/1\r\nsw1(config-if)#"),
		connectortest.Reply("end\n", "end\r\nsw1#"),
	)...)
	ctx := t.Context()
	if err := s.Login(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Run(ctx, terminal.Command{Text: "interface Gi1/0/1", Mode: terminal.ModeConfig}); err != nil {
		t.Fatal(err)
	}
	if s.Mode() != terminal.ModeConfigSub {
		t.Fatalf("mode = %v", s.Mode())
	}
	if err := s.Enter(ctx, terminal.ModePrivileged); err != nil || s.Mode() != terminal.ModePrivileged {
		t.Fatalf("leave: %v %v", err, s.Mode())
	}
}

func TestDisruptiveQuestionNeedsAllow(t *testing.T) {
	t.Parallel()
	s, dev := session(t, steps(
		connectortest.Reply("reload\n", "reload\r\nProceed with reload? [confirm]"),
		connectortest.Reply("\x03", "\r\nsw1#"),
	)...)
	if err := s.Login(t.Context()); err != nil {
		t.Fatal(err)
	}
	_, err := s.Run(t.Context(), terminal.Command{Text: "reload"})
	if code(err) != failure.CodeInteraction || failure.Reason(err) != string(terminal.ReasonDisruptive) {
		t.Fatalf("err = %v", err)
	}
	if s.Mode() != terminal.ModePrivileged {
		t.Errorf("session not resynchronized: %v", s.Mode())
	}
	_ = dev
}

func TestUnknownQuestionAborts(t *testing.T) {
	t.Parallel()
	s, _ := session(t, steps(
		connectortest.Reply("clear counters\n", "clear counters\r\nClear \"show interface\" counters on all interfaces [confirm]"),
		connectortest.Reply("\x03", "\r\nsw1#"),
	)...)
	if err := s.Login(t.Context()); err != nil {
		t.Fatal(err)
	}
	_, err := s.Run(t.Context(), terminal.Command{Text: "clear counters"})
	if code(err) != failure.CodeInteraction || failure.Reason(err) != string(terminal.ReasonUnanswered) {
		t.Fatalf("err = %v", err)
	}
}

func save() terminal.Procedure {
	return terminal.Procedure{
		Name:    "save",
		Steps:   []terminal.Command{{Text: "copy running-config startup-config", Timeout: time.Second}},
		Success: []terminal.Signature{terminal.Sig("save_ok", `(?m)^\[OK\]$|(?P<bytes>\d+) bytes copied`)},
		Failure: []terminal.Signature{terminal.Sig("flash_full", `(?i)insufficient (?:flash|space)`)},
	}
}

func TestProcedureNeedsEvidence(t *testing.T) {
	t.Parallel()
	ok, _ := session(t, steps(
		connectortest.Reply("copy running-config startup-config\n", "copy running-config startup-config\r\nDestination filename [startup-config]? "),
		connectortest.Reply("\n", "\r\nBuilding configuration...\r\n[OK]\r\nsw1#"),
	)...)
	if err := ok.Login(t.Context()); err != nil {
		t.Fatal(err)
	}
	rec, err := ok.Execute(t.Context(), save())
	if err != nil || rec.Evidence != "save_ok" || rec.Responses[0].Answered[0] != "dest_filename" {
		t.Fatalf("save: %+v %v", rec, err)
	}

	silent, _ := session(t, steps(
		connectortest.Reply("copy running-config startup-config\n", "copy running-config startup-config\r\nsw1#"),
	)...)
	if err := silent.Login(t.Context()); err != nil {
		t.Fatal(err)
	}
	if _, err := silent.Execute(t.Context(), save()); code(err) != failure.CodeUnconfirmed {
		t.Fatalf("a bare prompt confirmed the save: %v", err)
	}

	full, _ := session(t, steps(
		connectortest.Reply("copy running-config startup-config\n", "copy running-config startup-config\r\n%Error: Insufficient flash space\r\nsw1#"),
	)...)
	if err := full.Login(t.Context()); err != nil {
		t.Fatal(err)
	}
	if _, err := full.Execute(t.Context(), save()); code(err) != failure.CodeRejected || failure.Reason(err) != "flash_full" {
		t.Fatalf("err = %v", err)
	}
}

func TestDecodeGB18030(t *testing.T) {
	t.Parallel()
	// "描述" in GB18030.
	s, _ := session(t, steps(
		connectortest.Reply("show description\n", "show description\r\n\xc3\xe8\xca\xf6\r\nsw1#"),
	)...)
	if err := s.Login(t.Context()); err != nil {
		t.Fatal(err)
	}
	r, err := s.Run(t.Context(), terminal.Command{Text: "show description"})
	if err != nil || r.Text() != "描述" || r.Encoding != "gb18030" {
		t.Fatalf("%q %q %v", r.Text(), r.Encoding, err)
	}
}

func TestBusy(t *testing.T) {
	t.Parallel()
	s, _ := session(t, steps(
		connectortest.Reply("show slow\n", ""),
	)...)
	if err := s.Login(t.Context()); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan error, 1)
	go func() {
		_, err := s.Run(ctx, terminal.Command{Text: "show slow"})
		done <- err
	}()
	time.Sleep(100 * time.Millisecond)
	if _, err := s.Run(t.Context(), terminal.Command{Text: "show clock"}); code(err) != failure.CodeBusy {
		t.Errorf("concurrent run: %v", err)
	}
	cancel()
	if err := <-done; code(err) != failure.CodeCancelled {
		t.Errorf("cancelled run: %v", err)
	}
}

func TestCommandValidation(t *testing.T) {
	t.Parallel()
	s, _ := session(t)
	for _, text := range []string{"", "show\nreload", "show\x1b[2J"} {
		if _, err := s.Run(t.Context(), terminal.Command{Text: text}); code(err) != failure.CodeInvalid {
			t.Errorf("%q: %v", text, err)
		}
	}
}

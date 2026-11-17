package connector

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/gatework/net-connector/internal/terminal"
)

type reviewFailSink struct{}

func (reviewFailSink) Write([]byte) (int, error) { return 0, errors.New("sink failed") }
func reviewDevice(t *testing.T, p StaticDriver, sink io.Writer, responses []string) *Device {
	t.Helper()
	d, e := New(p, ConnectionConfig{Host: "fixture", Logger: sink, CommandTimeout: time.Second}, WithTransportFactory(func(context.Context, ConnectionConfig) (io.ReadWriteCloser, error) {
		a, b := net.Pipe()
		go func() {
			defer b.Close()
			io.WriteString(b, "sw#")
			s := bufio.NewScanner(b)
			for _, r := range responses {
				if !s.Scan() {
					return
				}
				io.WriteString(b, r)
			}
			io.Copy(io.Discard, b)
		}()
		return a, nil
	}))
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { d.Close() })
	return d
}
func TestStreamingLogFailureBeforeMatchHasNoReceipt(t *testing.T) {
	d := reviewDevice(t, fixtureDriver(), reviewFailSink{}, []string{"done\nsw#"})
	count := 0
	r, e := d.ExecuteCommand(t.Context(), Command{Text: "change"}, ExecuteOptions{OnReceipt: func(context.Context, StepResult) error { count++; return nil }})
	if e == nil || len(r.Steps()) != 0 || count != 0 {
		t.Fatalf("steps=%d receipts=%d err=%v", len(r.Steps()), count, e)
	}
}
func TestSensitiveHookLeaks(t *testing.T) {
	var log bytes.Buffer
	p := fixtureDriver()
	p.AfterCommand = func(ctx context.Context, _ Command, _ StepResult, x Executor) error {
		_, e := x.Execute(ctx, Command{Text: "show secret", OutputSensitive: true})
		return e
	}
	d := reviewDevice(t, p, &log, []string{"done\nsw#", "PASSWORD-SECRET\nsw#"})
	_, e := d.ExecuteCommand(t.Context(), Command{Text: "show"}, ExecuteOptions{})
	if e != nil {
		t.Fatal(e)
	}
	if strings.Contains(log.String(), "PASSWORD-SECRET") {
		t.Fatal("OutputSensitive hook output leaked: " + log.String())
	}
}

//nolint:contextcheck // An independent call context proves that scope expiry cancels and joins admitted work.
func TestOperationExpiresAndDrainsAdmittedCall(t *testing.T) {
	d := reviewDevice(t, fixtureDriver(), nil, []string{"done\nsw#"})
	entered := make(chan struct{})
	release := make(chan struct{})
	cancelled := make(chan struct{})
	done := make(chan error, 1)
	outer := make(chan error, 1)
	go func() {
		outer <- d.WithOperation(t.Context(), func(ctx context.Context, o *Operation) error {
			go func() {
				_, e := o.ExecuteCommand(t.Context(), Command{Text: "show"}, ExecuteOptions{OnReceipt: func(ctx context.Context, _ StepResult) error {
					close(entered)
					<-ctx.Done()
					close(cancelled)
					<-release
					return nil
				}})
				done <- e
			}()
			<-entered
			return nil
		})
	}()
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		close(release)
		t.Fatal("scope did not cancel admitted call")
	}
	if e := d.Close(); e != nil {
		t.Errorf("Close failed while draining: %v", e)
	}
	select {
	case e := <-outer:
		t.Errorf("scope returned before draining: %v", e)
	default:
	}
	close(release)
	<-done
	<-outer
}
func TestInvalidTerminalAllowsWrite(t *testing.T) {
	p := fixtureDriver()
	p.Grammar.PrivilegeCommand = "enable\nwrite erase"
	p.Grammar.PrivilegePrompt = testPatternZero()
	if _, e := New(p, ConnectionConfig{Host: "fixture"}); e == nil {
		t.Fatal("invalid privilege command/prompt accepted")
	}
}
func TestFailedHookStillConsumesBudget(t *testing.T) {
	p := fixtureDriver()
	p.Prepare = func(ctx context.Context, c Command, x Executor) (Command, bool, error) {
		_, e := x.Execute(ctx, Command{Text: "query"})
		if !errors.Is(e, ErrDevice) {
			return c, false, e
		}
		return c, false, nil
	}
	d := reviewDevice(t, p, nil, []string{"% Invalid input\nsw#", "ok\nsw#"})
	r, e := d.ExecuteCommand(t.Context(), Command{Text: "main"}, ExecuteOptions{MaxOutputBytes: 6})
	if !errors.Is(e, ErrScriptLimit) {
		t.Fatalf("failed query's raw bytes not charged: err=%v steps=%d", e, len(r.Steps()))
	}
}
func TestCancellationInLastCallback(t *testing.T) {
	d := reviewDevice(t, fixtureDriver(), nil, []string{"ok\nsw#"})
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	r, e := d.ExecuteCommand(ctx, Command{Text: "main"}, ExecuteOptions{OnStep: func(context.Context, StepResult) error { cancel(); return nil }})
	if !errors.Is(e, context.Canceled) {
		t.Fatalf("late cancellation lost: err=%v steps=%d connected=%v", e, len(r.Steps()), d.Connected())
	}
}

func TestRenderedSecretLeaks(t *testing.T) {
	var log bytes.Buffer
	d := reviewDevice(t, fixtureDriver(), &log, []string{"pa\x1b[31mssword\x1b[0m\nsw#"})
	d.config.Password = "password"
	_, e := d.ExecuteCommand(t.Context(), Command{Text: "show"}, ExecuteOptions{})
	if e != nil {
		t.Fatal(e)
	}
	visible, e := terminal.Render(log.Bytes(), false)
	if e != nil {
		t.Fatal(e)
	}
	if strings.Contains(visible, "password") {
		t.Fatalf("credential reconstructed in log: %q", log.String())
	}
}

type reviewSingleClose struct {
	net.Conn
	closed bool
}

func (c *reviewSingleClose) Close() error {
	if c.closed {
		return errors.New("already closed")
	}
	c.closed = true
	return c.Conn.Close()
}
func TestTransportClosedTwice(t *testing.T) {
	d, e := New(fixtureDriver(), ConnectionConfig{Host: "fixture"}, WithTransportFactory(func(context.Context, ConnectionConfig) (io.ReadWriteCloser, error) {
		a, b := net.Pipe()
		go func() { defer b.Close(); io.WriteString(b, "sw#"); io.Copy(io.Discard, b) }()
		return &reviewSingleClose{Conn: a}, nil
	}))
	if e != nil {
		t.Fatal(e)
	}
	if e = d.Connect(t.Context()); e != nil {
		t.Fatal(e)
	}
	if e = d.Close(); e != nil {
		t.Fatalf("successful transport close repeated: %v, retained=%v", e, d.transport != nil)
	}
}

func TestPagerPreservesConsumedLineBoundaries(t *testing.T) {
	p := fixtureDriver()
	p.Grammar.PagerResponse = "\n"
	d := reviewDevice(t, p, nil, []string{"first\r\n--More--\n", "second\r\nsw#"})
	r, e := d.ExecuteCommand(t.Context(), Command{Text: "show"}, ExecuteOptions{})
	if e != nil {
		t.Fatal(e)
	}
	step := r.Steps()[0]
	if step.Response().Raw() != "first\r\n--More--\nsecond\r\nsw#" {
		t.Fatalf("raw=%q", step.Response().Raw())
	}
	if visible, _ := terminal.Render([]byte(testStepOutput(step)), true); !strings.Contains(visible, "first\n") || strings.Contains(testStepOutput(step), "--More--") || strings.Contains(testStepOutput(step), "firstsecond") {
		t.Fatalf("output=%q", testStepOutput(step))
	}
}
func TestCompletionLogFailurePreservesReceipt(t *testing.T) {
	d := reviewDevice(t, fixtureDriver(), reviewFailSink{}, []string{"sw#"})
	count := 0
	r, e := d.ExecuteCommand(t.Context(), Command{Text: "change"}, ExecuteOptions{OnReceipt: func(context.Context, StepResult) error { count++; return nil }})
	if e == nil || len(r.Steps()) != 1 || count != 1 {
		t.Fatalf("steps=%d receipts=%d err=%v", len(r.Steps()), count, e)
	}
}
func TestTerminalAndChallengePreflight(t *testing.T) {
	for _, kind := range []string{"privilege_newline", "privilege_without_prompt", "login_nil", "interaction_empty", "interaction_negative", "challenge_nil"} {
		t.Run(kind, func(t *testing.T) {
			p := fixtureDriver()
			cfg := ConnectionConfig{Host: "fixture"}
			switch kind {
			case "privilege_newline":
				p.Grammar.PrivilegeCommand = "enable\nwrite erase"
				p.Grammar.PrivilegePrompt = p.Grammar.CommandPrompt
			case "privilege_without_prompt":
				p.Grammar.PrivilegeCommand = "enable"
			case "login_nil":
				p.Grammar.LoginInteractions = []Interaction{{}}
			case "interaction_empty":
				p.Grammar.Interactions = []Interaction{{Pattern: testPattern(`.*`)}}
			case "interaction_negative":
				p.Grammar.Interactions = []Interaction{{Pattern: testPattern(`yes`), Limit: -1}}
			case "challenge_nil":
				cfg.Challenges = []Interaction{{}}
			}
			if _, e := New(p, cfg); !errors.Is(e, ErrInvalid) {
				t.Fatalf("invalid config accepted: %v", e)
			}
		})
	}
}

//nolint:contextcheck // An independent call context proves that scope expiry cancels and joins admitted work.
func TestHookExpiresAndDrainsAdmittedCall(t *testing.T) {
	entered := make(chan struct{})
	cancelled := make(chan struct{})
	release := make(chan struct{})
	child := make(chan error, 1)
	outer := make(chan error, 1)
	p := fixtureDriver()
	p.Prepare = func(ctx context.Context, c Command, x Executor) (Command, bool, error) {
		go func() {
			_, e := x.Execute(context.Background(), Command{Text: "query", Interactions: []Interaction{{Pattern: testPattern(`Question:`), Respond: func(ctx context.Context, _ string) (string, error) {
				close(entered)
				<-ctx.Done()
				close(cancelled)
				<-release
				return "", ctx.Err()
			}}}})
			child <- e
		}()
		<-entered
		return c, false, nil
	}
	d := reviewDevice(t, p, nil, []string{"Question:", "main\nsw#"})
	go func() { _, e := d.ExecuteCommand(t.Context(), Command{Text: "main"}, ExecuteOptions{}); outer <- e }()
	select {
	case <-cancelled:
	case <-time.After(time.Second):
		close(release)
		t.Fatal("hook scope did not cancel query")
	}
	if e := d.Close(); e != nil {
		t.Errorf("Close failed during hook drain: %v", e)
	}
	close(release)
	if e := <-child; !errors.Is(e, context.Canceled) {
		t.Errorf("query cancellation: %v", e)
	}
	if e := <-outer; !errors.Is(e, context.Canceled) {
		t.Errorf("hook returned with unfinished query but script continued: %v", e)
	}
}
func TestRenderedRedactionAcrossWrites(t *testing.T) {
	var b bytes.Buffer
	l := &logWriter{target: &b}
	if e := l.scope([]string{"password"}, false); e != nil {
		t.Fatal(e)
	}
	for _, part := range []string{"pa", "\x1b[", "31mss", "word\x1b[0m\n"} {
		if _, e := l.Write([]byte(part)); e != nil {
			t.Fatal(e)
		}
	}
	if e := l.finish(); e != nil {
		t.Fatal(e)
	}
	if strings.Contains(b.String(), "password") || strings.Contains(b.String(), "\x1b") {
		t.Fatalf("unsafe log: %q", b.String())
	}
}

func TestLegacyRecoveryUsesOnlyRecognizedFailureOnce(t *testing.T) {
	for _, tc := range []struct {
		name, message string
		allow         bool
		profileArgs   []string
		wantArgs      []string
		wantAttempts  int
	}{
		{"disabled", "RSA modulus too small", false, nil, nil, 1},
		{"rsa_default", "RSA modulus too small", true, nil, []string{"-1"}, 2},
		{"rsa_profile", "RSA modulus too small", true, []string{"-o", "HostKeyAlgorithms=+ssh-rsa"}, []string{"-o", "HostKeyAlgorithms=+ssh-rsa"}, 2},
		{"rsa_empty", "RSA modulus too small", true, []string{}, nil, 1},
		{"cipher", "Selected cipher type <unknown> not supported by server", true, nil, []string{"-c", "des"}, 2},
		{"unrecognized", "no matching key exchange method found", true, nil, nil, 1},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var attempts []ConnectionConfig
			p := fixtureDriver()
			p.Grammar.LegacyCryptoArguments = tc.profileArgs
			d, e := New(p, ConnectionConfig{Host: "fixture", AllowLegacyCrypto: tc.allow, LegacyCryptoArguments: []string{"forbidden-first-attempt"}}, WithTransportFactory(func(_ context.Context, cfg ConnectionConfig) (io.ReadWriteCloser, error) {
				attempts = append(attempts, cfg)
				a, b := net.Pipe()
				go func() { defer b.Close(); io.WriteString(b, tc.message) }()
				return a, nil
			}))
			if e != nil {
				t.Fatal(e)
			}
			e = d.Connect(t.Context())
			d.Close()
			if e == nil || len(attempts) != tc.wantAttempts {
				t.Fatalf("attempts=%d error=%v", len(attempts), e)
			}
			if len(attempts[0].LegacyCryptoArguments) != 0 {
				t.Fatalf("normal SSH used legacy arguments: %v", attempts[0].LegacyCryptoArguments)
			}
			if len(attempts) == 2 && !reflect.DeepEqual(attempts[1].LegacyCryptoArguments, tc.wantArgs) {
				t.Fatalf("recovery args=%v", attempts[1].LegacyCryptoArguments)
			}
		})
	}
}
func TestHostKeyReplacementStartsOnlyAfterChangedKey(t *testing.T) {
	for _, message := range []string{"REMOTE HOST IDENTIFICATION HAS CHANGED!", "Permission denied"} {
		t.Run(message, func(t *testing.T) {
			var attempts []ConnectionConfig
			d, e := New(fixtureDriver(), ConnectionConfig{Host: "fixture", HostKeyPolicy: "replace", KnownHosts: t.TempDir() + "/known_hosts"}, WithTransportFactory(func(_ context.Context, cfg ConnectionConfig) (io.ReadWriteCloser, error) {
				attempts = append(attempts, cfg)
				a, b := net.Pipe()
				go func() { defer b.Close(); io.WriteString(b, message) }()
				return a, nil
			}))
			if e != nil {
				t.Fatal(e)
			}
			e = d.Connect(t.Context())
			d.Close()
			if e == nil {
				t.Fatal("failed login accepted")
			}
			if attempts[0].replaceHostKey {
				t.Fatal("first attempt replaced trusted key")
			}
			want := 1
			if strings.Contains(message, "CHANGED") {
				want = 2
			}
			if len(attempts) != want {
				t.Fatalf("attempts=%d", len(attempts))
			}
			if want == 2 && !attempts[1].replaceHostKey {
				t.Fatal("recovery did not replace snapshot key")
			}
		})
	}
}

type reviewFailFirstClose struct {
	net.Conn
	calls int
}

func (c *reviewFailFirstClose) Close() error {
	c.calls++
	e := c.Conn.Close()
	if c.calls == 1 {
		return errors.New("cleanup failed")
	}
	return e
}
func TestTransportFailedCloseRemainsRetryable(t *testing.T) {
	var transport *reviewFailFirstClose
	d, e := New(fixtureDriver(), ConnectionConfig{Host: "fixture"}, WithTransportFactory(func(context.Context, ConnectionConfig) (io.ReadWriteCloser, error) {
		a, b := net.Pipe()
		transport = &reviewFailFirstClose{Conn: a}
		go func() { defer b.Close(); io.WriteString(b, "sw#"); io.Copy(io.Discard, b) }()
		return transport, nil
	}))
	if e != nil {
		t.Fatal(e)
	}
	if e = d.Connect(t.Context()); e != nil {
		t.Fatal(e)
	}
	if e = d.Close(); e == nil {
		t.Fatal("close failure was lost")
	}
	if transport.calls != 2 || d.transport != nil {
		t.Fatalf("cleanup retry calls=%d retained=%v", transport.calls, d.transport != nil)
	}
	if e = d.Close(); e != nil || transport.calls != 2 {
		t.Fatalf("successful cleanup repeated: %v calls=%d", e, transport.calls)
	}
}
func TestReceiptSurvivesCallbackFailures(t *testing.T) {
	for _, which := range []string{"receipt", "step"} {
		t.Run(which, func(t *testing.T) {
			d := reviewDevice(t, fixtureDriver(), nil, []string{"done\nsw#"})
			called := 0
			sentinel := errors.New("callback failed")
			opts := ExecuteOptions{OnReceipt: func(context.Context, StepResult) error {
				called++
				if which == "receipt" {
					return sentinel
				}
				return nil
			}, OnStep: func(context.Context, StepResult) error { return sentinel }}
			r, e := d.ExecuteCommand(t.Context(), Command{Text: "main"}, opts)
			if !errors.Is(e, sentinel) || len(r.Steps()) != 1 || called != 1 {
				t.Fatalf("steps=%d receipts=%d error=%v", len(r.Steps()), called, e)
			}
		})
	}
}
func TestExpiredHookDoesNotReviveInLaterHook(t *testing.T) {
	var saved Executor
	p := fixtureDriver()
	p.Prepare = func(_ context.Context, c Command, x Executor) (Command, bool, error) {
		if saved == nil {
			saved = x
		}
		return c, false, nil
	}
	p.AfterCommand = func(ctx context.Context, _ Command, _ StepResult, _ Executor) error {
		_, e := saved.Execute(ctx, Command{Text: "forbidden"})
		if !errors.Is(e, ErrScope) {
			return errors.New("old hook scope revived")
		}
		return nil
	}
	d := reviewDevice(t, p, nil, []string{"done\nsw#"})
	if _, e := d.ExecuteCommand(t.Context(), Command{Text: "main"}, ExecuteOptions{}); e != nil {
		t.Fatal(e)
	}
}

func TestPagedRunningConfigPreservesEveryLine(t *testing.T) {
	p := fixtureDriver()
	p.Grammar.PagerResponse = "\n"
	d := reviewDevice(t, p, nil, []string{"show config\r\ninterface A\r\n--More--\n", " description B\r\nsw#"})
	r, e := d.RunningConfig(t.Context())
	if e != nil {
		t.Fatal(e)
	}
	config, ok := r.Config()
	if !ok || !strings.Contains(config, "interface A\n") || !strings.Contains(config, " description B\n") || strings.Contains(config, "--More--") {
		t.Fatalf("config=%q", config)
	}
	if r.Steps()[0].Response().Raw() != "show config\r\ninterface A\r\n--More--\n description B\r\nsw#" {
		t.Fatalf("raw=%q", r.Steps()[0].Response().Raw())
	}
}

type reviewCleanupFailure struct{ net.Conn }

func (c *reviewCleanupFailure) Close() error { c.Conn.Close(); return errors.New("incomplete cleanup") }
func TestRecoveryWaitsForSuccessfulCleanup(t *testing.T) {
	for _, message := range []string{"Connection refused", "RSA modulus too small", "Selected cipher type <unknown> not supported by server", "REMOTE HOST IDENTIFICATION HAS CHANGED!"} {
		t.Run(message, func(t *testing.T) {
			attempts := 0
			d, e := New(fixtureDriver(), ConnectionConfig{Host: "fixture", HostKeyPolicy: "replace", KnownHosts: t.TempDir() + "/known_hosts", AllowLegacyCrypto: true, AllowTelnetFallback: true}, WithTransportFactory(func(context.Context, ConnectionConfig) (io.ReadWriteCloser, error) {
				attempts++
				a, b := net.Pipe()
				go func() { defer b.Close(); io.WriteString(b, message) }()
				return &reviewCleanupFailure{Conn: a}, nil
			}))
			if e != nil {
				t.Fatal(e)
			}
			if e = d.Connect(t.Context()); !errors.Is(e, errCleanup) || attempts != 1 {
				t.Fatalf("error=%v attempts=%d", e, attempts)
			}
			if d.transport == nil {
				t.Fatal("incomplete cleanup ownership discarded")
			}
		})
	}
}

func TestSensitiveInteractionProtectsEntireExchange(t *testing.T) {
	for _, profileInteraction := range []bool{false, true} {
		t.Run(fmt.Sprint(profileInteraction), func(t *testing.T) {
			var log bytes.Buffer
			p := fixtureDriver()
			c := Command{Text: "show"}
			rule := Interaction{Pattern: testPattern(`Question:`), Reply: "secret\n", Sensitive: true}
			if profileInteraction {
				p.Grammar.Interactions = []Interaction{rule}
			} else {
				c.Interactions = []Interaction{rule}
			}
			d := reviewDevice(t, p, &log, []string{"PRIVATE-BEFORE\nQuestion:", "PRIVATE-AFTER\nsw#"})
			if _, e := d.ExecuteCommand(t.Context(), c, ExecuteOptions{}); e != nil {
				t.Fatal(e)
			}
			if strings.Contains(log.String(), "PRIVATE-") {
				t.Fatalf("sensitive exchange leaked: %q", log.String())
			}
		})
	}
}

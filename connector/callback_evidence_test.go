package connector

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"golang.org/x/text/encoding/simplifiedchinese"

	expect "github.com/gatework/go-expect"
	"github.com/gatework/net-connector/internal/textcodec"
)

func TestHookAndReceiptErrorsBothSurvive(t *testing.T) {
	hookErr, receiptErr := errors.New("private hook body"), errors.New("private receipt body")
	p := fixtureDriver()
	p.AfterCommand = func(context.Context, Command, StepResult, Executor) error { return hookErr }
	d, writes := fixtureDevice(t, p, []string{"done\nsw#"})
	receipts := 0
	r, err := d.ExecuteScript(t.Context(), Script{Commands: []Command{{Text: "first"}, {Text: "never"}}}, ExecuteOptions{OnReceipt: func(context.Context, StepResult) error {
		receipts++
		return receiptErr
	}})
	if !errors.Is(err, hookErr) || !errors.Is(err, receiptErr) {
		t.Fatalf("missing simultaneous error: %v", err)
	}
	var classified *Error
	if !errors.As(err, &classified) || classified.Code != "after_command_failed" {
		t.Fatalf("primary classification changed: %v", err)
	}
	if len(r.Steps()) != 1 || receipts != 1 {
		t.Fatalf("steps=%d receipts=%d", len(r.Steps()), receipts)
	}
	if strings.Contains(fmt.Sprintf("%+v %#v", err, err), "private") {
		t.Fatal("error formatting exposed callback bodies")
	}
	_ = d.Close()
	if len(*writes) != 1 {
		t.Fatal("replayed or continued command")
	}
}

type cancelConfig struct{ entered chan struct{} }

func TestAfterLoginReceivesVerifiedResponse(t *testing.T) {
	p := fixtureDriver()
	var retained Response
	p.AfterLogin = func(_ context.Context, s StepResult) (LoginState, error) {
		retained = s.Response()
		text, err := s.Response().Rendered()
		if err == nil && text != "sw#" {
			return LoginState{}, errors.New("login rendering changed")
		}
		return LoginState{Labels: map[string]string{"ha_state": "active"}}, err
	}
	d, _ := fixtureDevice(t, p, nil)
	if err := d.Connect(t.Context()); err != nil {
		t.Fatal(err)
	}
	if d.LoginLabel("ha_state") != "active" {
		t.Fatal("login state missing")
	}
	if text, err := retained.Output(); text != "sw#" || err != nil {
		t.Fatalf("login output=%q err=%v", text, err)
	}
}

func (cancelConfig) MatchPrompt(_, current string) (expect.Pattern, error) {
	return expect.Line(strings.TrimSpace(current)), nil
}
func (cancelConfig) Validate(context.Context, Command, StepResult, Executor) error { return nil }
func (s cancelConfig) Finish(ctx context.Context, _ Result) (string, error) {
	close(s.entered)
	<-ctx.Done()
	return "", ctx.Err()
}

func TestCloseCancelsAdmittedCallbacks(t *testing.T) {
	for _, phase := range []string{"operation", "login", "finish"} {
		t.Run(phase, func(t *testing.T) {
			entered := make(chan struct{})
			var d *Device
			var run func(context.Context) error
			p := fixtureDriver()
			switch phase {
			case "operation":
				var err error
				d, err = New(p, ConnectionConfig{Host: "unused"})
				if err != nil {
					t.Fatal(err)
				}
				run = func(ctx context.Context) error {
					return d.WithOperation(ctx, func(ctx context.Context, _ *Operation) error {
						close(entered)
						<-ctx.Done()
						return ctx.Err()
					})
				}
			case "login":
				p.AfterLogin = func(ctx context.Context, _ StepResult) (LoginState, error) {
					close(entered)
					<-ctx.Done()
					return LoginState{}, ctx.Err()
				}
				d, _ = fixtureDevice(t, p, nil)
				run = d.Connect
			case "finish":
				p.Collector = func() ConfigStrategy { return cancelConfig{entered} }
				d, _ = fixtureDevice(t, p, []string{"show config\nbody\nsw#"})
				run = func(ctx context.Context) error { _, err := d.RunningConfig(ctx); return err }
			}
			ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
			defer cancel()
			done := make(chan error, 1)
			go func() { done <- run(ctx) }()
			select {
			case <-entered:
			case <-ctx.Done():
				t.Fatal("callback not entered")
			}
			if err := d.Close(); err != nil {
				t.Fatal(err)
			}
			select {
			case err := <-done:
				if !errors.Is(err, context.Canceled) {
					t.Fatalf("close did not cancel callback: %v", err)
				}
			case <-ctx.Done():
				t.Fatal("callback retained caller context")
			}
		})
	}
}

func TestRejectedResponseRetainsVerifiedEvidence(t *testing.T) {
	for _, encoded := range []bool{false, true} {
		t.Run(fmt.Sprint(encoded), func(t *testing.T) {
			wire := "配置\r\n% Invalid input\r\nsw#"
			if encoded {
				var err error
				wire, err = simplifiedchinese.GBK.NewEncoder().String(wire)
				if err != nil {
					t.Fatal(err)
				}
			}
			d, _ := fixtureDevice(t, fixtureDriver(), []string{wire})
			r, err := d.ExecuteCommand(t.Context(), Command{Text: "show"}, ExecuteOptions{})
			if !errors.Is(err, ErrDevice) || len(r.Steps()) != 0 || len(r.Attempts()) != 1 {
				t.Fatalf("unexpected rejection: %v", err)
			}
			a := r.Attempts()[0]
			view := a.Response()
			if !a.Complete() || view.Raw() != wire || view.RawPrompt() != "\nsw#" {
				t.Fatal("raw evidence lost")
			}
			output, err := view.Output()
			if err != nil || !strings.Contains(output, "配置") {
				t.Fatalf("output=%q error=%v", output, err)
			}
			visible, err := view.Rendered()
			if err != nil || visible != "配置\n% Invalid input\nsw#" {
				t.Fatalf("rendered=%q error=%v", visible, err)
			}
			prompt, err := view.Prompt()
			if err != nil || prompt != "\nsw#" {
				t.Fatalf("prompt=%q error=%v", prompt, err)
			}
			_ = d.Close()
			if after, err := view.Output(); err != nil || after != output {
				t.Fatal("response mutated after close")
			}
			encodedJSON, err := json.Marshal(view)
			if err != nil || strings.Contains(fmt.Sprintf("%+v %#v %s", view, view, encodedJSON), "配置") {
				t.Fatal("response leaked in diagnostics")
			}
		})
	}
}

func TestUnavailableResponseConversionIsExplicit(t *testing.T) {
	for _, complete := range []bool{false, true} {
		t.Run(fmt.Sprint(complete), func(t *testing.T) {
			wire := "partial \xff"
			want := ErrIncomplete
			if complete {
				wire += "\nsw#"
				want = textcodec.ErrEncoding
			}
			d, _ := fixtureDevice(t, fixtureDriver(), []string{wire})
			timeout := 20 * time.Millisecond
			r, err := d.ExecuteCommand(t.Context(), Command{Text: "show", Timeout: &timeout}, ExecuteOptions{})
			if err == nil || len(r.Attempts()) != 1 {
				t.Fatalf("expected failed attempt: %v", err)
			}
			a := r.Attempts()[0]
			if a.Complete() != complete || a.Response().Raw() != wire {
				t.Fatal("completion or raw changed")
			}
			for _, get := range []func() (string, error){a.Response().Output, a.Response().Rendered, a.Response().Prompt} {
				if _, err := get(); !errors.Is(err, want) {
					t.Fatalf("conversion error=%v want=%v", err, want)
				}
			}
		})
	}
	if _, err := (Response{}).Output(); !errors.Is(err, ErrIncomplete) {
		t.Fatal("zero response must be incomplete")
	}
}

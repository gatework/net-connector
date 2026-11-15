package connector

import (
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/gatework/net-connector/internal/textcodec"
)

func TestSingleAcceptedRequiresOneMatchingMainCommand(t *testing.T) {
	d, _ := fixtureDevice(t, fixtureDriver(), []string{
		"show\r\nvalue\r\nsw#", "first\r\none\r\nsw#", "second\r\ntwo\r\nsw#",
	})
	single, err := d.ExecuteCommand(t.Context(), Command{Text: "show"}, ExecuteOptions{})
	if err != nil {
		t.Fatal(err)
	}
	multiple, err := d.ExecuteScript(t.Context(), Script{Commands: []Command{{Text: "first"}, {Text: "second"}}}, ExecuteOptions{})
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		name     string
		result   Result
		expected string
	}{
		{name: "no receipt", expected: "show"},
		{name: "multiple receipts", result: multiple, expected: "first"},
		{name: "different command", result: single, expected: "other secret"},
		{name: "identity keeps whitespace", result: single, expected: " show "},
		{name: "empty command", result: single},
	} {
		t.Run(test.name, func(t *testing.T) {
			step, err := test.result.SingleAccepted(test.expected)
			if !errors.Is(err, ErrInvalidResult) || step.Response().Raw() != "" {
				t.Fatalf("step=%v err=%v", step, err)
			}
			classified, ok := errors.AsType[*Error](err)
			if !ok || classified.Code != "invalid_command_result" || classified.Phase != "parse" {
				t.Fatalf("missing safe classification: %v", err)
			}
			if strings.Contains(fmt.Sprintf("%v %+v %#v", err, err, err), "secret") {
				t.Fatal("command leaked in diagnostic")
			}
		})
	}
}

func TestStepBodyPreservesVerifiedContent(t *testing.T) {
	for _, test := range []struct {
		name, wire, want string
	}{
		{
			name: "echo indentation repeated command and separators",
			wire: "show\r\n  child\r\nshow\r\n\r\nsw#",
			want: "  child\nshow\n\n",
		},
		{
			name: "no echo and leading blank line",
			wire: "\r\n  child\r\nshow\r\nsw#",
			want: "\n  child\nshow\n",
		},
		{
			name: "first line containing command is body",
			wire: "show result\r\nsw#",
			want: "show result\n",
		},
		{
			name: "matching echo whitespace",
			wire: "  show  \r\n value\r\nsw#",
			want: " value\n",
		},
		{
			name: "terminal visible text",
			wire: "show\r\nold\rnew\r\nsw#",
			want: "new\n",
		},
		{
			name: "legacy encoding",
			wire: "show\r\n description \xd6\xd0\xce\xc4\r\nsw#",
			want: " description 中文\n",
		},
		{name: "empty body with echo", wire: "show\r\nsw#"},
		{name: "empty body without echo", wire: "sw#"},
	} {
		t.Run(test.name, func(t *testing.T) {
			d, _ := fixtureDevice(t, fixtureDriver(), []string{test.wire})
			result, err := d.ExecuteCommand(t.Context(), Command{Text: "show"}, ExecuteOptions{})
			if err != nil {
				t.Fatal(err)
			}
			step, err := result.SingleAccepted("show")
			if err != nil {
				t.Fatal(err)
			}
			if err := d.Close(); err != nil {
				t.Fatal(err)
			}
			body, err := step.Body()
			if err != nil || body != test.want {
				t.Fatalf("body=%q want=%q err=%v", body, test.want, err)
			}
			if step.Response().Raw() != test.wire {
				t.Fatal("body extraction changed retained wire evidence")
			}
		})
	}
}

func TestStepBodyRetainsPromptLeadingNewlines(t *testing.T) {
	p := fixtureDriver()
	p.Grammar.CommandPrompt = testPattern(`\n+sw#$`)
	d, _ := fixtureDevice(t, p, []string{"show\nbody\n\nsw#"})
	result, err := d.ExecuteCommand(t.Context(), Command{Text: "show"}, ExecuteOptions{})
	if err != nil {
		t.Fatal(err)
	}
	step, err := result.SingleAccepted("show")
	if err != nil {
		t.Fatal(err)
	}
	body, err := step.Body()
	if err != nil || body != "body\n\n" {
		t.Fatalf("body=%q err=%v", body, err)
	}
}

func TestStepBodyRejectsUnavailableAndInconsistentEvidence(t *testing.T) {
	conversionErr := errors.New("secret conversion body")
	for _, test := range []struct {
		name  string
		data  *responseData
		cause error
	}{
		{name: "zero response", cause: ErrIncomplete},
		{name: "unverified text", data: &responseData{rendered: "secret body\nsw#", prompt: "\nsw#"}, cause: ErrIncomplete},
		{name: "missing prompt", data: &responseData{rendered: "secret body", verifiedText: true}},
		{name: "newline is not prompt", data: &responseData{rendered: "secret body\n", prompt: "\n", verifiedText: true}},
		{name: "mismatched prompt", data: &responseData{rendered: "secret body\nother#", prompt: "\nsw#", verifiedText: true}},
		{name: "failed rendering", data: &responseData{renderErr: conversionErr}, cause: conversionErr},
		{name: "failed prompt conversion", data: &responseData{promptErr: conversionErr}, cause: conversionErr},
	} {
		t.Run(test.name, func(t *testing.T) {
			step := StepResult{command: Command{Text: "secret command"}, response: Response{data: test.data}}
			body, err := step.Body()
			if body != "" || !errors.Is(err, ErrInvalidResult) || test.cause != nil && !errors.Is(err, test.cause) {
				t.Fatalf("body=%q err=%v", body, err)
			}
			if strings.Contains(fmt.Sprintf("%v %+v %#v", err, err, err), "secret") {
				t.Fatal("command, response or cause leaked in diagnostic")
			}
		})
	}
}

func TestStepBodyRejectsBackupPreservationViews(t *testing.T) {
	for _, mode := range []configTextMode{configTextBackupSource, configTextPreserveInvalid} {
		t.Run(fmt.Sprint(mode), func(t *testing.T) {
			d, _ := fixtureDevice(t, fixtureDriver(), []string{"show config\r\n description 中文\xff\r\nsw#"})
			result, err := d.ExecuteCommand(t.Context(), Command{Text: "show config"}, ExecuteOptions{textMode: mode})
			if err != nil {
				t.Fatal(err)
			}
			step, err := result.SingleAccepted("show config")
			if err != nil {
				t.Fatal(err)
			}
			if _, err := step.Response().Rendered(); err != nil {
				t.Fatal("backup view became unavailable:", err)
			}
			if body, err := step.Body(); body != "" || !errors.Is(err, ErrInvalidResult) || !errors.Is(err, ErrIncomplete) {
				t.Fatalf("backup view treated as strictly verified body: %q %v", body, err)
			}
		})
	}
}

func TestSingleAcceptedRejectsInvalidEncoding(t *testing.T) {
	d, _ := fixtureDevice(t, fixtureDriver(), []string{"show\r\n\xff\r\nsw#"})
	result, err := d.ExecuteCommand(t.Context(), Command{Text: "show"}, ExecuteOptions{})
	if !errors.Is(err, textcodec.ErrEncoding) || len(result.Attempts()) != 1 {
		t.Fatalf("invalid response evidence lost: %v", err)
	}
	if _, err := result.SingleAccepted("show"); !errors.Is(err, ErrInvalidResult) {
		t.Fatalf("invalid encoding produced an accepted receipt: %v", err)
	}
}

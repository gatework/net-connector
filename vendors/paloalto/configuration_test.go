package paloalto

import (
	"errors"
	"strings"
	"testing"

	"github.com/gatework/net-connector/connector"
)

func TestPaloAltoSetConfigurationPreservesQuotesAndWhitespace(t *testing.T) {
	valid := []string{
		"set description \"first  \nsecond\"",
		`set description "first
second"
set system host-name firewall`,
		`set description 'first\
second'

set system host-name firewall`,
		`set description "escaped \"quote\"
second"`,
		`set description 'backslash\'
set system host-name firewall`,
		`set description escaped\"quote
set description ` + "\\",
	}
	for _, text := range valid {
		got, err := cleanOutput(text+"\n[edit]\nadmin@fw#", "admin@fw#")
		if err != nil || got != text {
			t.Fatalf("valid: %q got %q %v", text, got, err)
		}
	}
	for _, text := range []string{
		"", "<config/>", "set description \"first\nsecond", "set description 'first\nsecond",
		"set description \"first\nsecond\"\nnot-a-set-command", "set description 'first\\'\nnot-a-set-command",
	} {
		if _, err := cleanOutput(text, "admin@fw#"); !errors.Is(err, connector.ErrIncomplete) {
			t.Fatalf("invalid: %q %v", text, err)
		}
	}
}

func TestPaloAltoCollectionBoundaryPreservesMultilineCertificate(t *testing.T) {
	for _, state := range []string{"active", "passive"} {
		prompt := "audit@fw(" + state + ")#"
		want := "set shared certificate example certificate \"first  \n[edit]\nlast\"\nset system host-name fw"
		wire := prompt + " show\r\n" + strings.ReplaceAll(want, "\n", "\r\n") + "\r\n[edit]                                                                          \r\n" + prompt + " "
		got, err := cleanOutput(wire, prompt)
		if err != nil || got != want {
			t.Fatalf("state %s: boundary extraction failed: %v", state, err)
		}
		if body := configurationBody(prompt+" show config diff\r\n"+prompt+" ", "show config diff", prompt); body != "" {
			t.Fatal("empty diff contains response boundary")
		}
		if body := configurationBody("show config diff\r\n+ changed\r\n"+prompt+" ", "show config diff", prompt); body != "+ changed" {
			t.Fatal("real diff lost")
		}
	}
}

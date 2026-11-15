package vendors

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gatework/net-connector/connector"
)

func TestPANCollectionAcceptsPaddedPrompts(t *testing.T) {
	events := panEvents("set system host-name fw", "", "")
	for i := range events {
		events[i].receive += " "
	}
	d, check := dialogue(t, "palo_alto", "admin@fw> ", events)
	r, err := d.RunningConfig(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if text, ok := r.Config(); !ok || text != "set system host-name fw" {
		t.Fatal("complete PAN config not accepted")
	}
	check()
}

func TestRadwareLoginNoticeAndReadOnlyDump(t *testing.T) {
	d, check := dialogue(t, "radware", "Confirm seeing above note [y]: ", []exchange{
		{"y\n", ">> Standalone ADC - Main# "},
		{"/cfg/dump\n", "/cfg/dump\r\nDisplay private keys? [y/n]: "},
		{"n\n", "\r\n/c/sys\r\n hostname example\r\n>> Standalone ADC - Configuration# "},
	})
	r, err := d.RunningConfig(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if text, ok := r.Config(); !ok || !strings.Contains(text, "hostname example") {
		t.Fatal("config missing")
	}
	check()
}

func TestRadwareLoginNoticeIsBoundedAndSpecific(t *testing.T) {
	p := lookupPlatform(t, "radware")
	for _, rule := range p.Terminal().LoginInteractions {
		if rule.Unlimited || rule.Limit != 1 {
			t.Fatal("login notice must be bounded")
		}
		for _, question := range []string{"Confirm saving to FLASH [y/n]:", "Confirm Sync to Peer [y/n]:", "Apply configuration? [y/n]:"} {
			if matchesPattern(rule.Pattern, question) {
				t.Fatal("login rule accepts write confirmation")
			}
		}
	}
	d, _ := dialogue(t, "radware", "Confirm seeing above note [y]: ", []exchange{{"y\n", "Confirm seeing above note [y]: "}})
	err := d.Connect(t.Context())
	if !errors.Is(err, connector.ErrAuthentication) {
		t.Fatalf("repeated notice not rejected: %v", err)
	}
}

func TestPANBackupPreservesMultilineQuotedWhitespace(t *testing.T) {
	want := "set description \"first  \nsecond\"\nset system host-name fw"
	d, check := dialogue(t, "palo_alto", "admin@fw>", panEvents(want, "", ""))
	path := filepath.Join(t.TempDir(), "pan.txt")
	_, err := d.Backup(t.Context(), connector.BackupOptions{Path: path})
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != want {
		t.Fatal("PAN backup altered multiline quoted whitespace")
	}
	check()
}

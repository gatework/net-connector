package driver_test

import (
	"strings"
	"testing"

	"github.com/gatework/net-connector/driver"
)

// FuzzReadOnly checks that no redirection is ever classified as read-only
// and that classification never panics.
func FuzzReadOnly(f *testing.F) {
	for _, s := range []string{"show run", "show run | include x", "show run > flash:x", "display cur | redirect a", "reload"} {
		f.Add(s)
	}
	v := driver.Verbs{"show", "display"}
	f.Fuzz(func(t *testing.T, cmd string) {
		if v.ReadOnly(cmd) && (strings.Contains(cmd, ">") || strings.Contains(strings.ToLower(cmd), "redirect")) {
			t.Fatalf("%q classified read-only", cmd)
		}
	})
}

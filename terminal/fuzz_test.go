package terminal

import (
	"strings"
	"testing"
	"unicode/utf8"
)

// FuzzResponse feeds arbitrary device bytes through decoding, rendering and
// classification: it must not panic and must yield valid UTF-8 without
// control characters other than tab.
func FuzzResponse(f *testing.F) {
	for _, s := range []string{
		"show version\r\nok\r\n", "\x1b[16D   \x1b[16D\b\b\r\n", "\xc3\xe8\xca\xf6\r\n", "\xff\xfe\x00", "a\rb\bc\r\n%LINK-3-UPDOWN",
	} {
		f.Add([]byte(s))
	}
	g := Grammar{Prompts: []Prompt{{Mode: ModePrivileged, Expr: Host + `#`}}, Errors: []Signature{Sig(ReasonInvalidInput, `^%`)}, Async: []string{`^%LINK`}}
	c, err := g.compile()
	if err != nil {
		f.Fatal(err)
	}
	s := &Session{c: c}
	f.Fuzz(func(t *testing.T, raw []byte) {
		r := s.response(Command{Text: "show version"}, string(raw), "sw1#")
		for _, l := range append(r.Body, r.Raw) {
			if !utf8.ValidString(l) {
				t.Fatalf("invalid UTF-8: %q", l)
			}
			if strings.ContainsFunc(l, func(c rune) bool { return c < 0x20 && c != '\t' && c != '\n' }) {
				t.Fatalf("control character survived: %q", l)
			}
		}
	})
}

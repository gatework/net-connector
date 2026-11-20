package terminal

import (
	"bytes"
	"strings"
	"unicode/utf8"

	"github.com/charmbracelet/x/ansi"
	"github.com/saintfish/chardet"
	"golang.org/x/text/encoding"
	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/encoding/traditionalchinese"
)

// decode returns raw as UTF-8 and the source encoding. Valid UTF-8 is kept
// as is; otherwise the detected Chinese legacy encoding is used when it
// decodes strictly and round-trips, and invalid bytes are replaced last.
func decode(raw []byte) (string, string) {
	if utf8.Valid(raw) {
		return string(raw), "utf-8"
	}
	candidates := []struct {
		name string
		enc  encoding.Encoding
	}{{"gb18030", simplifiedchinese.GB18030}, {"big5", traditionalchinese.Big5}}
	if r, err := chardet.NewTextDetector().DetectBest(raw); err == nil && strings.EqualFold(r.Charset, "Big5") {
		candidates[0], candidates[1] = candidates[1], candidates[0]
	}
	for _, c := range candidates {
		out, err := c.enc.NewDecoder().Bytes(raw)
		if err != nil || !utf8.Valid(out) {
			continue
		}
		if back, err := c.enc.NewEncoder().Bytes(out); err == nil && bytes.Equal(back, raw) {
			return string(out), c.name
		}
	}
	return strings.ToValidUTF8(string(raw), "�"), "invalid"
}

// render applies backspaces and carriage returns the way a terminal shows
// them and removes escape sequences. Each returned line is what a screen
// would display.
func render(text string) []string {
	text = ansi.Strip(strings.ReplaceAll(text, "\x00", ""))
	text = strings.ReplaceAll(text, "\r\n", "\n")
	lines := strings.Split(text, "\n")
	for i, l := range lines {
		lines[i] = cook(l)
	}
	return lines
}

// cook renders one line: "\r" returns to column 0 and overwrites, "\b"
// moves back one column, and other control characters (BEL, stray C0
// bytes, DEL) are not displayed.
func cook(line string) string {
	if !strings.ContainsFunc(line, control) {
		return strings.TrimRight(line, " \t")
	}
	var buf []rune
	col := 0
	for _, r := range line {
		switch r {
		case '\r':
			col = 0
		case '\b':
			col = max(col-1, 0)
		case '\t':
			buf, col = put(buf, col, r)
		default:
			if control(r) {
				continue
			}
			buf, col = put(buf, col, r)
		}
	}
	return strings.TrimRight(string(buf), " \t")
}

func put(buf []rune, col int, r rune) ([]rune, int) {
	if col < len(buf) {
		buf[col] = r
	} else {
		buf = append(buf, r)
	}
	return buf, col + 1
}

func control(r rune) bool { return r < 0x20 && r != '\t' || r == 0x7f }

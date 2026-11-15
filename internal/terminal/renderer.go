// Package terminal renders the subset of terminal editing used by device CLIs.
package terminal

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/gatework/net-connector/internal/textcodec"
)

// ErrLimit reports an oversized terminal line or escape sequence.
var ErrLimit = errors.New("terminal: line or escape sequence exceeds limit")

// ErrEncoding reports invalid text when strict decoding is required.
var ErrEncoding = errors.New("terminal: invalid UTF-8")

// Renderer applies bounded terminal edits before emitting complete lines.
type Renderer struct {
	// Encoding selects decoding after a complete terminal line is assembled.
	// Empty preserves the original UTF-8 behavior.
	Encoding      string
	target        io.Writer
	line          []byte
	cursor, limit int
	state         byte
	params        []byte
	strict        bool
}

// New creates a renderer that borrows w and bounds each line by limit.
func New(w io.Writer, limit int, strict bool) *Renderer {
	return &Renderer{target: w, limit: limit, strict: strict}
}

// Render applies terminal edits and returns the visible UTF-8 text.
func Render(input []byte, strict bool) (string, error) {
	return RenderEncoded(input, strict, "")
}

// RenderEncoded applies terminal byte edits before converting visible lines.
func RenderEncoded(input []byte, strict bool, encoding string) (string, error) {
	var b strings.Builder
	r := New(&b, 32<<20, strict)
	r.Encoding = encoding
	if _, e := r.Write(input); e != nil {
		return "", e
	}
	if e := r.Finish(); e != nil {
		return "", e
	}
	return b.String(), nil
}
func (r *Renderer) Write(p []byte) (int, error) {
	for i, b := range p {
		if r.state != 0 {
			if e := r.escape(b); e != nil {
				return i, e
			}
			continue
		}
		switch b {
		case 27:
			r.state = 'e'
		case 8:
			r.cursor = max(0, r.cursor-1)
		case 13:
			r.cursor = 0
		case 10:
			if e := r.emit(true); e != nil {
				return i, e
			}
		default:
			if b < 32 && b != 9 {
				continue
			}
			if r.cursor >= r.limit || r.cursor < 0 {
				return i, ErrLimit
			}
			// Sequential text is the common path; append directly instead of
			// allocating a one-byte padding slice for every input byte.
			if r.cursor == len(r.line) {
				r.line = append(r.line, b)
			} else if r.cursor > len(r.line) {
				r.line = append(r.line, bytes.Repeat([]byte{' '}, r.cursor-len(r.line)+1)...)
			}
			r.line[r.cursor] = b
			r.cursor++
		}
	}
	return len(p), nil
}

// Finish emits any pending line without adding a newline.
func (r *Renderer) Finish() error {
	if len(r.line) > 0 {
		return r.emit(false)
	}
	return nil
}
func (r *Renderer) escape(b byte) error {
	switch r.state {
	case 'e':
		switch b {
		case '[':
			r.state = 'c'
			r.params = r.params[:0]
		case ']':
			r.state = 'o'
		default:
			r.state = 0
		}
	case 'o':
		switch b {
		case 7:
			r.state = 0
		case 27:
			r.state = 's'
		}
	case 's':
		if b == '\\' {
			r.state = 0
		} else {
			r.state = 'o'
		}
	case 'c':
		return r.control(b)
	}
	return nil
}
func (r *Renderer) emit(newline bool) error {
	line := r.line
	if r.Encoding != "bytes" {
		line = bytes.TrimRight(line, " \t")
	}
	if r.Encoding != "" && r.Encoding != "utf-8" && r.Encoding != "bytes" {
		text, _, err := textcodec.Decode(string(line), r.Encoding)
		if err == nil {
			line = []byte(text)
		} else if r.strict {
			return ErrEncoding
		}
	}
	if r.Encoding != "bytes" && !utf8.Valid(line) {
		if r.strict {
			return ErrEncoding
		}
		var b strings.Builder
		for len(line) > 0 {
			v, n := utf8.DecodeRune(line)
			if v == utf8.RuneError && n == 1 {
				fmt.Fprintf(&b, "\\x%02X", line[0])
			} else {
				b.Write(line[:n])
			}
			line = line[n:]
		}
		line = []byte(b.String())
	}
	if n, e := r.target.Write(line); e != nil {
		return e
	} else if n != len(line) {
		return io.ErrShortWrite
	}
	if newline {
		if n, e := io.WriteString(r.target, "\n"); e != nil {
			return e
		} else if n != 1 {
			return io.ErrShortWrite
		}
	}
	r.line = r.line[:0]
	r.cursor = 0
	return nil
}

// RenderString avoids byte buffers for ordinary UTF-8 lines. Terminal edits and
// malformed encodings still use the byte-oriented renderer.
func RenderString(input string, strict bool) (string, error) {
	if !utf8.ValidString(input) {
		return Render([]byte(input), strict)
	}
	for i := range len(input) {
		c := input[i]
		if c < 32 && c != '\n' && c != '\t' && !(c == '\r' && i+1 < len(input) && input[i+1] == '\n') {
			return Render([]byte(input), strict)
		}
	}
	var out strings.Builder
	start := 0
	changed := false
	for start < len(input) {
		n := strings.IndexByte(input[start:], '\n')
		end := len(input)
		newline := n >= 0
		if newline {
			end = start + n
		}
		line := input[start:end]
		// The byte renderer resets its cursor on CR but retains the existing line.
		if newline {
			line = strings.TrimSuffix(line, "\r")
		}
		if len(line) > 32<<20 {
			return "", ErrLimit
		}
		line = strings.TrimRight(line, " \t")
		originalEnd := end
		if newline {
			originalEnd++
		}
		differs := len(line) != end-start
		if differs && !changed {
			out.Grow(len(input))
			out.WriteString(input[:start])
			changed = true
		}
		if changed {
			out.WriteString(line)
			if newline {
				out.WriteByte('\n')
			}
		}
		start = originalEnd
	}
	if !changed {
		return input, nil
	}
	return out.String(), nil
}

func (r *Renderer) control(b byte) error {
	if b >= 0x40 && b <= 0x7e {
		n := 1
		var digits strings.Builder
		for _, x := range r.params {
			if x >= '0' && x <= '9' {
				digits.WriteString(string(x))
			} else if digits.String() != "" {
				break
			}
		}
		if digits.String() != "" {
			v, e := strconv.Atoi(digits.String())
			if e != nil {
				return ErrLimit
			}
			n = v
		}
		if err := r.applyControl(b, n, digits.String() == ""); err != nil {
			return err
		}
		r.state = 0
	} else if b >= 0x20 && b <= 0x3f {
		if len(r.params) >= 64 {
			return ErrLimit
		}
		r.params = append(r.params, b)
	} else {
		r.state = 0
	}
	return nil
}

func (r *Renderer) applyControl(b byte, n int, empty bool) error {
	switch b {
	case 'C':
		if n > r.limit-r.cursor {
			return ErrLimit
		}
		r.cursor += n
	case 'D':
		r.cursor = max(0, r.cursor-n)
	case 'G':
		if n > r.limit {
			return ErrLimit
		}
		r.cursor = max(0, n-1)
	case 'K':
		if empty {
			n = 0
		}
		switch n {
		case 0:
			r.line = r.line[:min(r.cursor, len(r.line))]
		case 1:
			for i := range min(r.cursor+1, len(r.line)) {
				r.line[i] = ' '
			}
		case 2:
			r.line = r.line[:0]
			r.cursor = 0
		}
	}
	return nil
}

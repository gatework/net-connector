package connector

import (
	"encoding/json"
	"fmt"
	"unicode/utf8"

	"github.com/gatework/net-connector/internal/terminal"
	"github.com/gatework/net-connector/internal/textcodec"
)

// Response is an immutable snapshot of received bytes and verified text.
// A completed prompt does not imply acceptance, valid encoding, or persistence.
// Text accessors never decode again; unavailable text returns ErrIncomplete.
// The zero value contains no received evidence. Formatting exposes only metadata.
type Response struct{ data *responseData }

// Only the receiving operation can populate data, before exposing a snapshot.
// Steps, attempts, and callback receipts subsequently share it without mutation.
type responseData struct {
	raw, rawPrompt, output, rendered, prompt, encoding string
	outputErr, renderErr, promptErr                    error
	rawWarning                                         *TextWarning
	verifiedText                                       bool // strict conversion, not a backup preservation view
}

// Raw returns received source bytes without decoding or redaction.
func (r Response) Raw() string {
	if r.data == nil {
		return ""
	}
	return r.data.raw
}

// RawPrompt returns the original prompt bytes without decoding or redaction.
func (r Response) RawPrompt() string {
	if r.data == nil {
		return ""
	}
	return r.data.rawPrompt
}

// Encoding returns the encoding recorded when the response was converted.
func (r Response) Encoding() string {
	if r.data == nil {
		return ""
	}
	return r.data.encoding
}

// Output returns decoded output before terminal edits, or its conversion error.
func (r Response) Output() (string, error) {
	if r.data == nil {
		return "", ErrIncomplete
	}
	if r.data.outputErr != nil {
		return "", r.data.outputErr
	}
	return r.data.output, nil
}

// Rendered returns output with terminal edits applied, or its conversion error.
func (r Response) Rendered() (string, error) {
	if r.data == nil {
		return "", ErrIncomplete
	}
	return r.data.rendered, r.data.renderErr
}

// Prompt returns the decoded, rendered prompt or its conversion error.
func (r Response) Prompt() (string, error) {
	if r.data == nil {
		return "", ErrIncomplete
	}
	return r.data.prompt, r.data.promptErr
}
func (r Response) String() string { return fmt.Sprintf("connector.Response{bytes:%d}", len(r.Raw())) }

// GoString formats byte counts without response contents.
func (r Response) GoString() string { return r.String() }

// MarshalJSON encodes byte counts without response contents.
func (r Response) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		Bytes int `json:"bytes"`
	}{len(r.Raw())})
}

// convert verifies the complete response once, before command acceptance checks.
// diagnostic preserves decoded text even where terminal edits erase a device error.
func (r *responseData) convert() (diagnostic string, err error) {
	r.verifiedText = false
	wire := r.output
	output, encoding, err := textcodec.Decode(wire, "auto")
	if err != nil {
		r.outputErr, r.renderErr, r.promptErr = err, err, err
		return "", err
	}
	r.encoding = encoding
	diagnostic = output
	if encoding != "utf-8" {
		output, err = terminal.RenderEncoded([]byte(wire), true, encoding)
		if err != nil {
			r.outputErr, r.renderErr, r.promptErr = err, err, err
			return "", err
		}
	}
	r.output, r.outputErr = output, nil
	r.rendered, r.renderErr = terminal.RenderString(output, true)
	if encoding == "utf-8" {
		r.prompt, r.promptErr = terminal.RenderString(r.rawPrompt, true)
	} else {
		r.prompt, r.promptErr = terminal.RenderEncoded([]byte(r.rawPrompt), true, encoding)
	}
	if r.renderErr != nil {
		return diagnostic, r.renderErr
	}
	r.verifiedText = r.promptErr == nil
	return diagnostic, r.promptErr
}

// convertBackup preserves undecodable source bytes without weakening commands
// used by configuration parsers. The original response remains immutable.
func (r *responseData) convertBackup() (string, error) {
	r.verifiedText = false
	wire := r.output
	diagnostic := r.raw
	if !utf8.ValidString(r.raw) {
		var count int
		var offsets []int
		diagnostic, _, count, offsets = textcodec.BackupViewSource(r.raw)
		r.rawWarning = sourceWarning(r.raw, count, offsets)
	}
	if utf8.ValidString(wire) {
		return r.convert()
	}
	visible, err := terminal.RenderEncoded([]byte(wire), false, "bytes")
	if err != nil {
		r.outputErr, r.renderErr, r.promptErr = err, err, err
		return "", err
	}
	output, encoding, _ := textcodec.BackupView(visible)
	r.encoding = encoding
	r.output = output
	r.rendered, r.renderErr = terminal.RenderString(output, true)
	r.outputErr = nil
	_, promptEncoding, promptErr := textcodec.Decode(r.rawPrompt, "auto")
	if promptErr != nil {
		r.promptErr = promptErr
	} else {
		r.prompt, r.promptErr = terminal.RenderEncoded([]byte(r.rawPrompt), true, promptEncoding)
	}
	// Device rejection checks inspect both pre-edit and visible text. Editing an
	// error out of the terminal must never turn rejection into a successful backup.
	if r.raw != wire {
		diagnostic, _, _ = textcodec.BackupView(wire)
	}
	if r.renderErr != nil {
		return diagnostic, r.renderErr
	}
	return diagnostic, r.promptErr
}

// convertOriginal is limited to explicit backup preservation; parsers retain strict decoding.
func (r *responseData) convertOriginal() (string, error) {
	r.verifiedText = false
	output, err := terminal.RenderEncoded([]byte(r.output), false, "bytes")
	if err != nil {
		return "", err
	}
	prompt, err := terminal.RenderEncoded([]byte(r.rawPrompt), true, "auto")
	if err != nil {
		return "", err
	}
	r.output, r.rendered, r.prompt = output, output, prompt
	r.outputErr, r.renderErr, r.promptErr = nil, nil, nil
	r.encoding = "original-bytes"
	diagnostic, _, _ := textcodec.BackupView(r.raw)
	return diagnostic, nil
}

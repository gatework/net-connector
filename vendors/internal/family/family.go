// Package family holds grammar fragments shared by vendor families, named
// after the CLI mechanism they describe rather than a vendor. Each
// function returns fresh values.
package family

import (
	"fmt"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/gatework/net-connector/driver"
	"github.com/gatework/net-connector/terminal"
)

// Login is the common authentication dialogue: in-band username and
// password prompts, refusals, lockouts and a declined password change.
func Login() terminal.Login {
	return terminal.Login{
		Username: []string{`(?i)(?:login|user ?name)\s*:`},
		Password: []string{`(?i)password\s*:`},
		Failed: []terminal.Signature{
			terminal.Sig(terminal.ReasonLoginFailed, `(?i)(?:% ?)?(?:login invalid|login incorrect|authentication failed|access denied|bad passwords?|permission denied|incorrect password|username or password (?:is )?(?:wrong|invalid|error))`),
		},
		Locked: []terminal.Signature{
			terminal.Sig(terminal.ReasonLocked, `(?i)(?:user|account) (?:is |has been )?locked|too many (?:authentication )?failures|(?:user|account) (?:is )?blocked`),
		},
		Expired: []terminal.Rule{
			{Name: "decline_password_change", Pattern: `(?i)(?:change (?:the password )?now|modify the password)\?\s*\[Y/N\]:?`, Reply: terminal.Answer("N")},
		},
		Timeout: 30 * time.Second,
	}
}

// Pagers answer the "more" prompts of every family with a space.
func Pagers() []terminal.Rule {
	return []terminal.Rule{
		{Name: "more", Pattern: `(?i)(?:^|[\r\n])[ \t]*(?:\x1b\[[0-9;]*[A-Za-z])*(?:--+ ?More ?--+|---\(more(?: \d+%)?\)---)(?:\x1b\[[0-9;]*[A-Za-z])*`, Reply: terminal.Key(" "), Limit: -1},
		{Name: "press_any_key", Pattern: `(?i)Press any key to continue(?: \(Q to quit\))?`, Reply: terminal.Key(" "), Limit: -1},
	}
}

// Questions are the generic shapes of a question awaiting an answer. They
// all carry an explicit choice or default, so ordinary output that happens
// to end with "?" at a chunk boundary is not mistaken for a question.
func Questions() []string {
	return []string{
		`(?i)\[y(?:es)?/n(?:o)?\]\s*:?`,
		`(?i)\(y(?:es)?/n(?:o)?\)\s*:?`,
		`(?i)\[y\]/n\s*:?`,
		`(?i)\[confirm\]`,
		`\?\s*\[[^\]\r\n]*\]\s*:?`,
		`(?i)(?:press|hit) (?:the )?(?:enter|return) key[^\r\n]*`,
	}
}

// CaretErrors are the rejections of CLIs that point at the bad token with
// "^" (IOS, NX-OS, Comware, VRP, Centec, Hillstone).
func CaretErrors() []terminal.Signature {
	return []terminal.Signature{
		terminal.Sig(terminal.ReasonInvalidInput, `(?i)^\s*%\s*(?:Invalid input detected|Unrecognized command found|Unknown command)`),
		terminal.Sig(terminal.ReasonIncomplete, `(?i)^\s*%\s*Incomplete command`),
		terminal.Sig(terminal.ReasonAmbiguous, `(?i)^\s*%\s*Ambiguous command`),
		terminal.Sig(terminal.ReasonWrongParam, `(?i)^\s*%\s*(?:Wrong parameter|Too many parameters|Invalid parameter)`),
		terminal.Sig(terminal.ReasonInvalidInput, `(?i)^\s*%?\s*Invalid (?:parameter|command) detected`),
		terminal.Sig(terminal.ReasonPermission, `(?i)^\s*%?\s*Permission denied`),
	}
}

// ErrorLines are rejections reported as "Error: ..." (Comware, VRP,
// Hillstone) and semantic "does not exist" errors.
func ErrorLines() []terminal.Signature {
	return []terminal.Signature{
		terminal.Sig(terminal.ReasonNotFound, `(?i)^\s*(?:%\s*)?(?:Error:\s*)?.*(?:does not exist|not exist|not found|no such)`),
		terminal.Sig(terminal.ReasonBusy, `(?i)^\s*(?:Error:\s*)?.*(?:system is busy|is busy|try again later)`),
		terminal.Sig(terminal.ReasonCommandFailed, `(?i)^\s*Error:`),
	}
}

// Warnings are notices that do not reject the command.
func Warnings() []terminal.Signature {
	return []terminal.Signature{
		terminal.Sig(terminal.ReasonWarning, `(?i)^\s*(?:%\s*)?Warning:`),
		terminal.Sig(terminal.ReasonWarning, `(?i)^\s*Info:`),
	}
}

// AsyncLogs match log messages a device pushes to the terminal.
func AsyncLogs() []string {
	return []string{
		// IOS / NX-OS: "*Nov 19 08:00:01.123: %LINK-3-UPDOWN:" or "2026 Nov 19 08:00:01 sw %ETH..."
		`^\*?(?:\d{4} )?[A-Z][a-z]{2}\s+\d+ (?:\d{4} )?[\d:.]+(?: \S+)?: ?%[\w-]+-\d+-[\w-]+:`,
		// Comware / VRP: "%Nov 19 08:00:01:123 2026 sw IFNET/3/PHY_UPDOWN:" and "%%10IFNET/3/..."
		`^%%?\d*[A-Z][a-z]{2}\s+\d+ [\d:.]+ \d{4} \S+ \S+/\d+/\S+`,
		`^\s*%%\d+\w+/\d+/\w+`,
		`^\s*#[A-Z][a-z]{2}\s+\d+ [\d:.]+ \d{4} \S+ \S+/\d+/\S+`,
	}
}

// Comware prompts: <host> user view, [host] system view, [host-xxx] sub
// views. VRP marks pending changes with "~" or "*" ahead of the hostname.
func Comware() []terminal.Prompt {
	return []terminal.Prompt{
		{Mode: terminal.ModeUser, Expr: `<(?P<pending>[~*]?)` + terminal.Host + `>`},
		{Mode: terminal.ModeConfigSub, Expr: `\[(?P<pending>[~*]?)` + terminal.Host + `-[^\]\r\n]+\]`},
		{Mode: terminal.ModeConfig, Expr: `\[(?P<pending>[~*]?)` + terminal.Host + `\]`},
	}
}

// IOS prompts: host>, host#, host(config)#, host(config-if)#.
func IOS() []terminal.Prompt {
	return []terminal.Prompt{
		{Mode: terminal.ModeConfigSub, Expr: terminal.Host + `\(config-[^)\r\n]+\)#`},
		{Mode: terminal.ModeConfig, Expr: terminal.Host + `\(config\)#`},
		{Mode: terminal.ModePrivileged, Expr: terminal.Host + `#`},
		{Mode: terminal.ModeUser, Expr: terminal.Host + `>`},
	}
}

// Enable is the IOS-style privilege escalation.
func Enable() *terminal.Privilege {
	return &terminal.Privilege{
		Command: "enable", From: terminal.ModeUser,
		Password: []string{`(?i)password\s*:`},
		Failed:   []terminal.Signature{terminal.Sig(terminal.ReasonEnableFailed, `(?i)%\s*(?:Access denied|Bad secrets|Error in authentication)`)},
	}
}

// Grammar returns a grammar with the common login, pagers, questions,
// warnings and asynchronous logs.
func Grammar(prompts []terminal.Prompt, errors []terminal.Signature) terminal.Grammar {
	return terminal.Grammar{
		Login:     Login(),
		Prompts:   prompts,
		Pager:     Pagers(),
		Errors:    errors,
		Warnings:  Warnings(),
		Async:     AsyncLogs(),
		Questions: Questions(),
	}
}

// Command returns a command with a timeout.
func Command(text string, timeout time.Duration) terminal.Command {
	return terminal.Command{Text: text, Timeout: timeout}
}

var token = regexp.MustCompile(`^[A-Za-z0-9._:/@-]+$`)

// Token reports whether s is safe to place in a command as one word: a
// server address, file name, VRF or interface.
func Token(s string) bool { return token.MatchString(s) }

// ValidateExport checks the words an export command embeds.
func ValidateExport(server, file string, extra ...string) error {
	if !Token(server) || !Token(file) {
		return fmt.Errorf("%w: export server and file must be single safe words", driver.ErrUnsupported)
	}
	for _, e := range extra {
		if e != "" && !Token(e) {
			return fmt.Errorf("%w: export option %q", driver.ErrUnsupported, e)
		}
	}
	return nil
}

// Clean trims leading and trailing blank lines and drops lines matching
// any of drop, returning the configuration text.
func Clean(body []string, drop ...*regexp.Regexp) string {
	out := make([]string, 0, len(body))
	for _, l := range body {
		if slices.ContainsFunc(drop, func(re *regexp.Regexp) bool { return re.MatchString(l) }) {
			continue
		}
		out = append(out, l)
	}
	for len(out) > 0 && strings.TrimSpace(out[0]) == "" {
		out = out[1:]
	}
	for len(out) > 0 && strings.TrimSpace(out[len(out)-1]) == "" {
		out = out[:len(out)-1]
	}
	return strings.Join(out, "\n")
}

// FileSent is the generic evidence of a completed upload.
func FileSent() []terminal.Signature {
	return []terminal.Signature{
		terminal.Sig("file_sent", `(?im)^\s*(?:TFTP:\s*)?(?P<bytes>[1-9]\d*)\s+bytes?\s+(?:sent|copied)\b`),
		terminal.Sig("file_sent", `(?im)^\s*(?:File\s+)?(?:transfer(?:red)?|upload(?:ed|ing the file)?)(?:\s+(?:is|was|the file))?\s+(?:success(?:ful(?:ly)?)?|succeeded|complete(?:d)?)`),
	}
}

// FileFailed is the generic evidence of a failed upload.
func FileFailed() []terminal.Signature {
	return []terminal.Signature{
		terminal.Sig("transfer_timeout", `(?i)(?:timed? ?out|timeout was reached|no response from)`),
		terminal.Sig("transfer_refused", `(?i)(?:connection refused|can'?t connect|failed to connect|unreachable)`),
		terminal.Sig("file_missing", `(?i)(?:no such file|file (?:does )?not exist)`),
		terminal.Sig("transfer_failed", `(?i)(?:%\s*Error|Error:|failed to (?:put|upload|send)|transfer failed)`),
	}
}

// SaveFailed is the generic evidence of a failed save.
func SaveFailed() []terminal.Signature {
	return []terminal.Signature{
		terminal.Sig("flash_full", `(?i)(?:insufficient|not enough) (?:flash|space|memory)|no space left`),
		terminal.Sig("filesystem_busy", `(?i)file ?system is busy|is being (?:saved|written)`),
		terminal.Sig("save_failed", `(?i)(?:save|saving|write) (?:configuration )?(?:failed|error)|failed to save`),
	}
}

// ConfigRead is the ConfigReader of platforms that print the running
// configuration with one command. Vendor types embed it.
type ConfigRead struct {
	Command terminal.Command
	// Drop removes preamble lines such as "Building configuration...".
	Drop []*regexp.Regexp
}

// ConfigSteps returns the one read command.
func (c ConfigRead) ConfigSteps() []terminal.Command { return []terminal.Command{c.Command} }

// CleanConfig returns the body of the read command without dropped lines.
func (c ConfigRead) CleanConfig(rs []terminal.Response) (string, error) {
	if len(rs) != 1 {
		return "", fmt.Errorf("%w: configuration read has %d responses", driver.ErrUnsupported, len(rs))
	}
	text := Clean(rs[0].Body, c.Drop...)
	if text == "" {
		return "", fmt.Errorf("%w: empty configuration", driver.ErrUnsupported)
	}
	return text, nil
}

// Read returns a ConfigRead of command with a five-minute bound.
func Read(command string, drop ...*regexp.Regexp) ConfigRead {
	return ConfigRead{Command: Command(command, 5*time.Minute), Drop: drop}
}

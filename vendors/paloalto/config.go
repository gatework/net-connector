package paloalto

import (
	"fmt"
	"strings"

	"github.com/gatework/net-connector/driver"
	"github.com/gatework/net-connector/terminal"
)

// configSteps read the running configuration in set format. "show" in
// configuration mode prints the candidate, so it is only the running
// configuration when "show config diff" is empty before and after it.
var configSteps = []string{
	"set cli config-output-format set",
	"show config diff",
	"configure",
	"show",
	"exit",
	"show config diff",
}

// ConfigSteps returns the guarded set-format read.
func (PANOS) ConfigSteps() []terminal.Command {
	out := make([]terminal.Command, len(configSteps))
	for i, c := range configSteps {
		out[i] = terminal.Command{Text: c}
	}
	out[3].Timeout = configTimeout
	return out
}

// ErrUncommitted reports a candidate configuration with uncommitted
// changes: what "show" printed is not the running configuration.
var ErrUncommitted = fmt.Errorf("%w: candidate has uncommitted changes", driver.ErrUnsupported)

// CleanConfig requires both diffs to be empty and the body of "show" to be
// complete set commands.
func (PANOS) CleanConfig(rs []terminal.Response) (string, error) {
	if len(rs) != len(configSteps) {
		return "", fmt.Errorf("%w: configuration read has %d responses", driver.ErrUnsupported, len(rs))
	}
	for _, i := range []int{1, 5} {
		if strings.TrimSpace(rs[i].Text()) != "" {
			return "", ErrUncommitted
		}
	}
	body := rs[3].Body
	for len(body) > 0 {
		last := strings.TrimSpace(body[len(body)-1])
		if last != "" && last != "[edit]" {
			break
		}
		body = body[:len(body)-1]
	}
	text := strings.TrimSpace(strings.Join(body, "\n"))
	if !setCommands(text) {
		return "", fmt.Errorf("%w: configuration is not complete set commands", driver.ErrUnsupported)
	}
	return text, nil
}

// setCommands reports whether text is non-empty set commands with every
// quote closed; a quoted value may span lines (certificates).
func setCommands(text string) bool {
	if text == "" {
		return false
	}
	var quote byte
	for _, line := range strings.SplitAfter(text, "\n") {
		if quote == 0 {
			if strings.TrimSpace(line) == "" {
				continue
			}
			if !strings.HasPrefix(line, "set ") {
				return false
			}
		}
		escaped := false
		for i := range len(line) {
			switch b := line[i]; {
			case escaped:
				escaped = false
			case b == '\\' && quote != '\'':
				escaped = true
			case b == quote:
				quote = 0
			case quote == 0 && (b == '\'' || b == '"'):
				quote = b
			}
		}
	}
	return quote == 0
}

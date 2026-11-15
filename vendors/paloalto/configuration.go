package paloalto

import (
	"context"
	"fmt"
	"strings"

	expect "github.com/gatework/go-expect"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/vendors/internal/driver"
)

type configPolicy struct {
	driver.BaseConfigPolicy
	diffs int
}

func (p *configPolicy) MatchPrompt(command, current string) (expect.Pattern, error) {
	prompt := strings.Trim(current, " \t\x00\r\n")
	if (command == "configure" || command == "exit") && (strings.HasSuffix(prompt, ">") || strings.HasSuffix(prompt, "#")) {
		suffix := "#"
		if command == "exit" {
			suffix = ">"
		}
		prompt = prompt[:len(prompt)-1] + suffix
	}
	return expect.Line(prompt), nil
}
func (p *configPolicy) Validate(_ context.Context, command connector.Command, result connector.StepResult, _ connector.Executor) error {
	if command.Text != "show config diff" {
		return nil
	}
	p.diffs++
	output, err := result.Response().Output()
	if err != nil {
		return err
	}
	prompt, err := result.Response().Prompt()
	if err != nil {
		return err
	}
	if configurationBody(output, command.Text, prompt) != "" {
		return configurationError("uncommitted_configuration", connector.ErrIncomplete)
	}
	return nil
}
func (p *configPolicy) SelectStep(steps []connector.StepResult) (connector.StepResult, error) {
	if p.diffs != 2 {
		return connector.StepResult{}, connector.ErrIncomplete
	}
	for _, step := range steps {
		if step.Command().Text == "show" {
			return step, nil
		}
	}
	return connector.StepResult{}, connector.ErrIncomplete
}
func (p *configPolicy) Clean(step connector.StepResult, _, prompt string) (string, error) {
	output, err := step.Response().Output()
	if err != nil {
		return "", err
	}
	return cleanOutput(output, prompt)
}

func cleanOutput(output, prompt string) (string, error) {
	text := configurationBody(output, "show", prompt)
	text = driver.Regex(`(?:\A|\n)[ \t]*\[edit\][ \t]*\z`).ReplaceAllString(text, "")
	text = strings.TrimSpace(text)
	if !setCommands(text) {
		return "", configurationError("unsupported_configuration_format", connector.ErrIncomplete)
	}
	return text, nil
}

func configurationError(message string, cause error) error {
	return fmt.Errorf("vendors: %s: %w", message, cause)
}

func configurationBody(text, command, prompt string) string {
	text = strings.ReplaceAll(text, "\r\n", "\n")
	prompt = strings.TrimSpace(strings.ReplaceAll(prompt, "\r\n", "\n"))
	// Keep whitespace inside the device's multiline certificate values intact.
	text = strings.TrimRight(text, " \t\r\n")
	if text == prompt {
		text = ""
	} else {
		text = strings.TrimSuffix(text, "\n"+prompt)
	}
	first, rest, ok := strings.Cut(text, "\n")
	echo := strings.TrimSpace(first)
	if echo == command || strings.TrimSpace(strings.TrimPrefix(echo, prompt)) == command {
		if !ok {
			return ""
		}
		text = rest
	}
	return strings.TrimSpace(text)
}

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
			b := line[i]
			if escaped {
				escaped = false
			} else if b == '\\' && quote != '\'' {
				escaped = true
			} else if b == quote {
				quote = 0
			} else if quote == 0 && (b == '\'' || b == '"') {
				quote = b
			}
		}
	}
	return quote == 0
}

func configFactory() func() connector.ConfigStrategy {
	return func() connector.ConfigStrategy {
		return driver.NewConfigStrategy(&configPolicy{})
	}
}

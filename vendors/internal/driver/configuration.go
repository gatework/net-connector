package driver

import (
	"context"
	"strings"

	expect "github.com/gatework/go-expect"

	"github.com/gatework/net-connector/connector"
)

// ConfigPolicy owns platform-specific prompt transitions, command
// validation, output selection and normalization.
type ConfigPolicy interface {
	MatchPrompt(command, current string) (expect.Pattern, error)
	Validate(ctx context.Context, command connector.Command, step connector.StepResult, executor connector.Executor) error
	SelectStep(steps []connector.StepResult) (connector.StepResult, error)
	Clean(step connector.StepResult, visible, prompt string) (string, error)
}

type configurationStrategy struct{ policy ConfigPolicy }

// NewConfigStrategy applies shared collection checks before delegating
// device-specific prompt handling and output normalization to policy.
func NewConfigStrategy(policy ConfigPolicy) connector.ConfigStrategy {
	if policy == nil {
		policy = BaseConfigPolicy{}
	}
	return &configurationStrategy{policy: policy}
}

func (s *configurationStrategy) MatchPrompt(command, current string) (expect.Pattern, error) {
	return s.policy.MatchPrompt(command, current)
}

func (s *configurationStrategy) Validate(ctx context.Context, command connector.Command, result connector.StepResult, executor connector.Executor) error {
	return s.policy.Validate(ctx, command, result, executor)
}

func (s *configurationStrategy) Finish(ctx context.Context, result connector.Result) (string, error) {
	if err := ctx.Err(); err != nil {
		return "", err
	}
	steps := result.Steps()
	if len(steps) == 0 {
		return "", connector.ErrIncomplete
	}
	step, err := s.policy.SelectStep(steps)
	if err != nil {
		return "", err
	}
	visible, err := step.Response().Rendered()
	if err != nil {
		return "", connector.ErrIncomplete
	}
	prompt, err := step.Response().Prompt()
	if err != nil {
		return "", connector.ErrIncomplete
	}
	prompt = strings.TrimSpace(prompt)
	if prompt == "" || RenderedBody(visible, step.Command().Text, prompt) == "" {
		return "", connector.ErrIncomplete
	}
	return s.policy.Clean(step, visible, prompt)
}

// BaseConfigPolicy keeps a valid prompt and returns visible output as-is.
type BaseConfigPolicy struct{}

// MatchPrompt matches the current terminal prompt for configuration collection.
func (BaseConfigPolicy) MatchPrompt(_ string, current string) (expect.Pattern, error) {
	return expect.Line(strings.Trim(current, " \t\x00\r\n")), nil
}

// Validate accepts a response without adding platform-specific validation.
func (BaseConfigPolicy) Validate(context.Context, connector.Command, connector.StepResult, connector.Executor) error {
	return nil
}

// SelectStep selects the final configuration response and rejects an empty collection.
func (BaseConfigPolicy) SelectStep(steps []connector.StepResult) (connector.StepResult, error) {
	if len(steps) == 0 {
		return connector.StepResult{}, connector.ErrIncomplete
	}
	return steps[len(steps)-1], nil
}

// Clean returns the visible response without platform-specific rewriting.
func (BaseConfigPolicy) Clean(_ connector.StepResult, visible, _ string) (string, error) {
	return visible, nil
}

// RenderedBody removes only the command echo and terminal prompt used as
// evidence; returned configuration bytes remain under the platform cleaner.
func RenderedBody(text, command, prompt string) string {
	text = strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(text), prompt))
	first, rest, ok := strings.Cut(text, "\n")
	if first == command || first == strings.TrimSpace(prompt)+command {
		if !ok {
			return ""
		}
		text = strings.TrimSpace(rest)
	}
	return text
}

// BaseConfigFactory creates a fresh default configuration strategy.
func BaseConfigFactory() func() connector.ConfigStrategy {
	return func() connector.ConfigStrategy { return NewConfigStrategy(BaseConfigPolicy{}) }
}

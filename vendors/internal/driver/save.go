package driver

import (
	"context"
	"regexp"
	"strings"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/internal/terminal"
)

var failure = regexp.MustCompile(`(?i)\b(?:error|failed|failure|denied|cannot|unable|unsuccessful|aborted)\b`)
var color = regexp.MustCompile(`\x1b\[[0-9;:]*m`)

// validateSaveConfirmation requires positive device confirmation and rejects failure evidence
// found in raw, rendered, or carriage-return-updated output.
func validateSaveConfirmation(ctx context.Context, result connector.Result, confirmation *regexp.Regexp) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if confirmation == nil {
		return connector.ErrUnconfirmed
	}
	steps := result.Steps()
	if len(steps) == 0 {
		return connector.ErrUnconfirmed
	}
	for _, step := range steps {
		if !stepConfirmed(step, confirmation) {
			return connector.ErrUnconfirmed
		}
	}
	return ctx.Err()
}

// stepConfirmed reports whether one accepted response carries the positive
// confirmation line and no failure evidence in its raw, rendered or
// carriage-return-updated output.
func stepConfirmed(step connector.StepResult, confirmation *regexp.Regexp) bool {
	raw := strings.TrimSuffix(step.Response().Raw(), step.Response().RawPrompt())
	history := color.ReplaceAllString(raw, "")
	history = strings.ReplaceAll(history, "\r", "\n")
	rendered, err := terminal.Render([]byte(raw), false)
	if err != nil {
		return false
	}
	historyRendered, err := terminal.Render([]byte(history), false)
	if err != nil || failure.MatchString(history) || failure.MatchString(historyRendered) || failure.MatchString(rendered) {
		return false
	}
	for line := range strings.SplitSeq(rendered, "\n") {
		if confirmation.MatchString(strings.TrimSpace(line)) {
			return true
		}
	}
	return false
}

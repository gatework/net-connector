package driver

import (
	"context"
	"regexp"
	"time"

	expect "github.com/gatework/go-expect"

	"github.com/gatework/net-connector/connector"
)

// CandidateSteps declares the fixed commands around a candidate change.
type CandidateSteps struct {
	// Enter opens the candidate and Leave returns to the operational prompt.
	Enter, Leave string
	// Check, when set, validates the candidate before any commit is sent.
	Check string
	// Commit commits the candidate; each commit must print Confirmation.
	Commit []connector.Command
	// Prompt is the prompt inside the candidate. Zero keeps the platform's
	// command prompt.
	Prompt expect.Pattern
}

// CandidateScript wraps body in the candidate steps. Body commands keep their
// source and line; the wrapping commands have no line.
func (c CandidateSteps) CandidateScript(body connector.Script) connector.Script {
	inside := func(command connector.Command) connector.Command {
		if command.Prompt.IsZero() {
			command.Prompt = c.Prompt
		}
		return command
	}
	script := connector.Script{Name: body.Name, Commands: []connector.Command{inside(connector.Command{Text: c.Enter})}}
	for _, command := range body.Commands {
		script.Commands = append(script.Commands, inside(command))
	}
	if c.Check != "" {
		script.Commands = append(script.Commands, inside(connector.Command{Text: c.Check}))
	}
	for _, commit := range c.Commit {
		script.Commands = append(script.Commands, inside(commit))
	}
	script.Commands = append(script.Commands, connector.Command{Text: c.Leave})
	return script
}

// CommitCommand declares one commit command with its own timeout.
func CommitCommand(text string, timeout time.Duration) connector.Command {
	return connector.Command{Text: text, Timeout: TimeoutPointer(timeout)}
}

// ValidateCommit requires every accepted commit command to carry the
// platform's positive confirmation line and no failure evidence. isCommit
// selects the commit commands among the accepted steps.
func ValidateCommit(ctx context.Context, result connector.Result, isCommit func(text string) bool, confirmation *regexp.Regexp) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	commits := 0
	for _, step := range result.Steps() {
		if !isCommit(step.Command().Text) {
			continue
		}
		commits++
		if !stepConfirmed(step, confirmation) {
			return connector.ErrUnconfirmed
		}
	}
	if commits == 0 {
		return connector.ErrUnconfirmed
	}
	return ctx.Err()
}

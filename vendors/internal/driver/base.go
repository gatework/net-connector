// Package driver contains reusable terminal and session mechanics for vendor
// platforms. Platform-specific commands, prompts and exceptions stay with the
// family packages.
package driver

import (
	"context"
	"regexp"
	"time"

	expect "github.com/gatework/go-expect"

	"github.com/gatework/net-connector/connector"
)

// Regex compiles a fixed platform expression during platform construction.
func Regex(expression string) *regexp.Regexp { return regexp.MustCompile(expression) }

// Regexps compiles an ordered set of fixed platform expressions.
func Regexps(expressions ...string) []*regexp.Regexp {
	patterns := make([]*regexp.Regexp, len(expressions))
	for i, expression := range expressions {
		patterns[i] = Regex(expression)
	}
	return patterns
}

// Pattern compiles a go-expect pattern during platform construction.
func Pattern(expression string) expect.Pattern {
	pattern, err := expect.Compile(expression)
	if err != nil {
		panic(err)
	}
	return pattern
}

// Interaction declares an unbounded command-session reply rule.
func Interaction(expression, response string) connector.Interaction {
	return connector.Interaction{Pattern: Pattern(expression), Reply: response, Capture: true, Unlimited: true}
}

// LoginInteraction declares a reply limited to one login event.
func LoginInteraction(expression, response string) connector.Interaction {
	interaction := Interaction(expression, response)
	interaction.Limit = 1
	interaction.Unlimited = false
	return interaction
}

// BaseTerminal supplies stable prompt, pager and authentication defaults.
func BaseTerminal(name string) connector.Terminal {
	return connector.Terminal{
		Name:                 name,
		UsernamePrompt:       Pattern(`(?i)(?:login|username|name):\s*\z`),
		PasswordPrompt:       Pattern(`(?i)password:\s*\z`),
		PrivilegePrompt:      Pattern(`#\s*\z`),
		Pager:                Pattern(`(?i)(?:\A|[\r\n])[ \t]*(?:--More--|---- More ----)[ \t\x00\x08]*(?:\r|\n|\z)`),
		PagerResponse:        " ",
		AuthenticationErrors: Regexps(`(?i)(?:authentication failed|permission denied|access denied|login incorrect)`),
	}
}

// Base implements connector.Driver and the platform name for a family type.
// Families embed it and add capability methods and optional hooks.
type Base struct {
	terminal         connector.Terminal
	collector        func() connector.ConfigStrategy
	saveConfirmation *regexp.Regexp
}

// NewBase completes a terminal with its command timeout and binds the
// configuration collector and positive save-confirmation rule. A nil
// saveConfirmation means saves are never confirmed.
func NewBase(t connector.Terminal, timeout time.Duration, collector func() connector.ConfigStrategy, saveConfirmation *regexp.Regexp) Base {
	t.CommandTimeout = timeout
	return Base{terminal: t.Clone(), collector: collector, saveConfirmation: saveConfirmation}
}

// Name returns the canonical platform key.
func (b Base) Name() string { return b.terminal.Name }

// Terminal returns an independent copy of the platform grammar.
func (b Base) Terminal() connector.Terminal { return b.terminal.Clone() }

// NewConfigCollector returns a fresh collection strategy for one run.
func (b Base) NewConfigCollector() connector.ConfigStrategy {
	if b.collector == nil {
		return nil
	}
	return b.collector()
}

// ValidateSave requires the platform's positive save confirmation.
func (b Base) ValidateSave(ctx context.Context, result connector.Result) error {
	return validateSaveConfirmation(ctx, result, b.saveConfirmation)
}

// PositionMarkerCommandErrors returns the rejection rules of CLIs that report
// errors with "% ... found at '^' position." plus a bare caret marker line.
func PositionMarkerCommandErrors() []*regexp.Regexp {
	return Regexps(
		`(?im)^[ \t]*%[ \t]+(?:(?:Unrecognized|Ambiguous|Incomplete)\s+command|Too\s+many\s+parameters)\s+found\s+at\s+'\^'\s+position\.`,
		`(?im)^[ \t]*error:`,
		`(?im)^[ \t]*Permission\s+denied\.`,
		`(?m)^\s*\^`,
	)
}

// YesNoConfirmations returns the replies for [Y/N] confirmations, the
// "press the enter key" pause and the default *.cfg file-name prompt.
func YesNoConfirmations() []connector.Interaction {
	return []connector.Interaction{
		Interaction(`(?i)Are\s+you\s+sure\?\s*\[Y/N\]`, "y\n"),
		Interaction(`(?i)press\s+the\s+enter\s+key\)`, "\n"),
		Interaction(`(?i)Continue\?\s*\[Y/N\]`, "y\n"),
		Interaction(`(?i)Please\s+input\s+the\s+file\s+name\(\*\.cfg\)\[[^\]]+\]\s*\z`, "\n"),
		Interaction(`(?i)overwrite\?\s*\[Y/N\]`, "y\n"),
	}
}

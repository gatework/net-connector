// Package facts collects basic device identity (model, serial number, software
// version) with read-only commands, so an inventory can be checked against
// what the devices themselves report.
package facts

import (
	"context"
	"errors"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/platform"
)

// ErrUnsupported means the platform does not declare fact collection.
var ErrUnsupported = errors.New("facts: unsupported platform")

// ErrNotReadOnly means a platform declared a fact command it does not itself
// classify as read-only; nothing is sent in that case.
var ErrNotReadOnly = errors.New("facts: command is not read-only")

// Facts is what a device reports about itself. A field the platform could not
// find is empty; OSVersion is always present.
type Facts struct {
	Hostname  string `json:"hostname,omitempty"`
	Model     string `json:"model,omitempty"`
	Serial    string `json:"serial,omitempty"`
	OSVersion string `json:"os_version"`
	// Uptime is the device's own uptime text, such as "1 week, 2 days".
	Uptime string `json:"uptime,omitempty"`
}

// Collector is the platform capability fact collection requires: the read-only
// commands to run and how to read their outputs, in command order.
type Collector interface {
	FactsCommands() []string
	ParseFacts(outputs []string) (Facts, error)
}

// readOnlyClassifier is implemented by platforms that classify commands.
type readOnlyClassifier interface {
	IsReadOnly(command string) bool
}

// Commands returns the platform's fact commands after checking each one
// against the platform's own read-only classification. It performs no I/O.
func Commands(p platform.Platform) ([]string, error) {
	collector, ok := p.(Collector)
	if !ok {
		return nil, ErrUnsupported
	}
	commands := collector.FactsCommands()
	if len(commands) == 0 {
		return nil, ErrUnsupported
	}
	classifier, ok := p.(readOnlyClassifier)
	for _, command := range commands {
		if !ok || !classifier.IsReadOnly(command) {
			return nil, ErrNotReadOnly
		}
	}
	return commands, nil
}

// Collect runs the platform's fact commands in one operation lease and parses
// their outputs. The accepted steps are returned even when parsing fails.
func Collect(ctx context.Context, d *connector.Device, p platform.Platform) (Facts, []connector.StepResult, error) {
	if d == nil || p == nil {
		return Facts{}, nil, ErrUnsupported
	}
	commands, err := Commands(p)
	if err != nil {
		return Facts{}, nil, err
	}
	collector, ok := p.(Collector)
	if !ok {
		return Facts{}, nil, ErrUnsupported
	}
	var steps []connector.StepResult
	outputs := make([]string, 0, len(commands))
	err = d.WithOperation(ctx, func(ctx context.Context, op *connector.Operation) error {
		for _, text := range commands {
			result, err := op.ExecuteCommand(ctx, connector.Command{Text: text}, connector.ExecuteOptions{})
			steps = append(steps, result.Steps()...)
			if err != nil {
				return err
			}
			step, err := result.SingleAccepted(text)
			if err != nil {
				return err
			}
			body, err := step.Body()
			if err != nil {
				return err
			}
			outputs = append(outputs, body)
		}
		return nil
	})
	if err != nil {
		return Facts{}, steps, err
	}
	found, err := collector.ParseFacts(outputs)
	return found, steps, err
}

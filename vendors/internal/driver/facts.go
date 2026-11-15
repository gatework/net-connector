package driver

import (
	"strings"

	"github.com/gatework/net-connector/facts"
	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/textfsm"
	"github.com/gatework/net-connector/vendors/internal/topoparse"
)

// FactsReader declares a platform's fact commands and the embedded TextFSM
// template that reads their concatenated outputs. The template captures
// VERSION and, where the platform prints them, HOSTNAME, MODEL, SERIAL and
// UPTIME, as one record.
type FactsReader struct {
	Commands []string
	Template string
}

// FactsCommands returns the read-only commands, in the order ParseFacts expects.
func (f FactsReader) FactsCommands() []string { return append([]string{}, f.Commands...) }

// ParseFacts reads the command outputs. Output without a software version is
// not recognized as this platform's.
func (f FactsReader) ParseFacts(outputs []string) (facts.Facts, error) {
	rows, err := textfsm.ParseTemplate(f.Template, strings.Join(outputs, "\n"))
	if err != nil {
		return facts.Facts{}, platform.NewDiagnosticError("unrecognized_output", "facts", err)
	}
	if len(rows) != 1 {
		return facts.Facts{}, platform.NewDiagnosticError("unrecognized_output", "facts", platform.ErrParse)
	}
	row := rows[0]
	found := facts.Facts{
		Hostname: topoparse.Field(row, "HOSTNAME"), Model: topoparse.Field(row, "MODEL"), Serial: topoparse.Field(row, "SERIAL"),
		OSVersion: topoparse.Field(row, "VERSION"), Uptime: topoparse.Field(row, "UPTIME"),
	}
	if found.OSVersion == "" {
		return facts.Facts{}, platform.NewDiagnosticError("unrecognized_output", "facts", platform.ErrParse)
	}
	return found, nil
}

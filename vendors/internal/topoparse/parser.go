// Package topoparse parses vendor topology output and interface configuration.
// Family packages own commands, templates, record counts, and platform rules.
package topoparse

import (
	"strings"

	"github.com/gatework/net-connector/internal/ifname"
	"github.com/gatework/net-connector/internal/terminal"
	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/textfsm"
	"github.com/gatework/net-connector/topology"
)

// Discovery protocols recorded on parsed neighbors.
const (
	ProtocolLLDP = "lldp"
	ProtocolCDP  = "cdp"
)

// Parser holds the template and validation rules for one CLI platform.
// Platform constructors live beside their vendor-specific parsing rules; the
// methods here provide the shared TextFSM and evidence boundary.
type Parser struct {
	NeighborTemplate, DescriptionTemplate string
	Protocol                              string
	CountNeighbors                        func(string) (int, bool)
	ValidateDescriptions                  func(string, []map[string]any) error
	CanonicalInterface                    func(string) string
	DecodeInterface, AppendInterfaceUnit  bool
	DecodeDescription, StrictDescription  bool
}

// ParseNeighbors requires parsed rows to match the independently counted records.
func (p Parser) ParseNeighbors(output string) ([]topology.Neighbor, error) {
	if p.NeighborTemplate == "" || p.CountNeighbors == nil {
		return nil, platform.ErrUnsupported
	}
	text, err := terminal.Render([]byte(output), true)
	if err != nil {
		return nil, platform.ErrParse
	}
	expected, empty := p.CountNeighbors(text)
	if expected < 0 {
		return nil, platform.ErrParse
	}
	rows, err := textfsm.ParseTemplate(p.NeighborTemplate, text)
	if err != nil || len(rows) != expected || len(rows) == 0 && !empty {
		return nil, platform.ErrParse
	}
	protocol := p.Protocol
	if protocol == "" {
		protocol = "lldp"
	}
	neighbors := make([]topology.Neighbor, 0, len(rows))
	for _, row := range rows {
		neighbors = append(neighbors, topology.Neighbor{
			LocalInterface:    strings.TrimSpace(Field(row, "LOCAL_INTERFACE")),
			NeighborName:      strings.TrimSpace(Field(row, "NEIGHBOR_NAME")),
			NeighborInterface: strings.TrimSpace(Field(row, "NEIGHBOR_INTERFACE")),
			ChassisID:         strings.TrimSpace(Field(row, "CHASSIS_ID")),
			Protocol:          protocol,
		})
	}
	return neighbors, nil
}

// ParseDescriptions validates and normalizes interface description records.
func (p Parser) ParseDescriptions(config string) (map[string]string, error) {
	if p.DescriptionTemplate == "" {
		return nil, platform.ErrUnsupported
	}
	text, err := terminal.Render([]byte(config), true)
	if err != nil {
		return nil, platform.ErrParse
	}
	rows, err := textfsm.ParseTemplate(p.DescriptionTemplate, text)
	if err != nil {
		return nil, platform.ErrParse
	}
	if p.ValidateDescriptions != nil {
		if err = p.ValidateDescriptions(text, rows); err != nil {
			return nil, err
		}
	}
	canonical := p.CanonicalInterface
	if canonical == nil {
		canonical = ifname.Key
	}
	out := make(map[string]string, len(rows))
	for _, row := range rows {
		name := Field(row, "INTERFACE")
		if p.DecodeInterface {
			name, err = DecodeQuoted(name, true)
			if err != nil {
				return nil, err
			}
		}
		name = canonical(name)
		if p.AppendInterfaceUnit && Field(row, "UNIT") != "" {
			name += "." + Field(row, "UNIT")
		}
		description := strings.TrimSpace(Field(row, "DESCRIPTION"))
		decoded, decodeErr := DecodeQuoted(description, p.DecodeDescription)
		if decodeErr != nil {
			if p.StrictDescription {
				return nil, decodeErr
			}
			decoded = description
		}
		if old, exists := out[name]; exists {
			if old != "" && decoded != "" && old != decoded {
				return nil, platform.NewDiagnosticError("ambiguous_description", "parse", platform.ErrParse)
			}
			if decoded == "" {
				continue
			}
		}
		out[name] = decoded
	}
	return out, nil
}

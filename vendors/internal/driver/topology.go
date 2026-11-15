package driver

import (
	"github.com/gatework/net-connector/internal/ifname"
	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/topology"
	"github.com/gatework/net-connector/vendors/internal/topoparse"
)

// NeighborPolicy owns one platform's neighbor command selection and parsing.
type NeighborPolicy struct {
	StatusCommand         string
	CommandText           string
	Parser                topoparse.Parser
	SelectNeighborCommand func(status, prompt string) (string, error)
}

// NewNeighborPolicy binds one fixed neighbor command to its parser.
func NewNeighborPolicy(command string, parser topoparse.Parser) NeighborPolicy {
	return NeighborPolicy{CommandText: command, Parser: parser}
}

// NeighborStatusCommand returns the optional preliminary status command.
func (p NeighborPolicy) NeighborStatusCommand() string { return p.StatusCommand }

// NeighborCommand selects the neighbor command using optional platform status.
func (p NeighborPolicy) NeighborCommand(status, prompt string) (string, error) {
	if p.SelectNeighborCommand != nil {
		return p.SelectNeighborCommand(status, prompt)
	}
	if p.CommandText == "" {
		return "", platform.ErrUnsupported
	}
	return p.CommandText, nil
}

// ParseNeighbors decodes the selected platform neighbor response.
func (p NeighborPolicy) ParseNeighbors(output string) ([]topology.Neighbor, error) {
	return p.Parser.ParseNeighbors(output)
}

// TopologyReader groups the read-only topology capabilities that share one
// parser: neighbor discovery, description parsing and interface identity.
type TopologyReader struct {
	NeighborPolicy
	DescriptionReader
	InterfaceIdentityPolicy
}

// NewTopologyReader declares the read-only topology capabilities for a
// platform whose neighbor command does not depend on device status.
func NewTopologyReader(neighborCommand string, parser topoparse.Parser) TopologyReader {
	return TopologyReader{
		NeighborPolicy:          NewNeighborPolicy(neighborCommand, parser),
		DescriptionReader:       DescriptionReader{Parser: parser},
		InterfaceIdentityPolicy: InterfaceIdentityPolicy{Parser: parser},
	}
}

// DescriptionReader parses a platform's running configuration.
type DescriptionReader struct{ Parser topoparse.Parser }

// ParseDescriptions decodes interface descriptions from the running configuration.
func (p DescriptionReader) ParseDescriptions(config string) (map[string]string, error) {
	return p.Parser.ParseDescriptions(config)
}

// InterfaceIdentityPolicy maps discovered names to the keys used by config
// parsers and device configuration commands.
type InterfaceIdentityPolicy struct{ Parser topoparse.Parser }

// InterfaceKey normalizes a discovered interface to its configuration identity.
func (p InterfaceIdentityPolicy) InterfaceKey(name string) string {
	if p.Parser.CanonicalInterface == nil {
		return ifname.Key(name)
	}
	return p.Parser.CanonicalInterface(name)
}

// ConfigName normalizes an interface name for rendered configuration commands.
func (InterfaceIdentityPolicy) ConfigName(name string) string {
	return ifname.ConfigName(name)
}

// DescriptionWriter implements command grammar shared by the
// currently writable families while retaining each family's mode transitions.
type DescriptionWriter struct{ Mode topology.WriteMode }

// NewDescriptionWriter binds interface description commands to the platform mode transitions.
func NewDescriptionWriter(mode topology.WriteMode) DescriptionWriter {
	return DescriptionWriter{Mode: mode}
}

// WriteMode returns the mode transitions required around description commands.
func (p DescriptionWriter) WriteMode() topology.WriteMode { return p.Mode }

// ChangeCommands renders commands that enter the interface and set its description.
func (DescriptionWriter) ChangeCommands(interfaceName, description string) ([]string, error) {
	return []string{"interface " + interfaceName, "description " + description}, nil
}

// WriteRestriction gives a read-only platform a stable explanation
// without making it implement a write capability.
type WriteRestriction struct{ Code string }

// UnavailableCode returns the stable reason this platform cannot change descriptions.
func (p WriteRestriction) UnavailableCode() string { return p.Code }

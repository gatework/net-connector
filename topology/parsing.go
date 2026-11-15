package topology

import (
	"errors"

	"github.com/gatework/net-connector/platform"
)

// ParseNeighbors delegates command-output interpretation to the resolved
// platform policy. A nil policy represents a platform without this behavior.
func ParseNeighbors(policy NeighborDiscovery, output string) ([]Neighbor, error) {
	if policy == nil {
		return nil, ErrUnsupported
	}
	neighbors, err := policy.ParseNeighbors(output)
	if err != nil {
		return nil, structuredParseError(err, "parse")
	}
	return neighbors, nil
}

// ParseDescriptions delegates configuration interpretation to the resolved
// platform policy while keeping topology orchestration vendor-neutral.
func ParseDescriptions(policy DescriptionReader, config string) (map[string]string, error) {
	if policy == nil {
		return nil, ErrUnsupported
	}
	descriptions, err := policy.ParseDescriptions(config)
	if err != nil {
		return nil, structuredParseError(err, "parse")
	}
	return descriptions, nil
}

func structuredParseError(err error, fallbackPhase string) error {
	if err == nil {
		return nil
	}
	if _, ok := errors.AsType[*Error](err); ok {
		return err
	}
	if metadata, ok := errors.AsType[platform.DiagnosticMetadata](err); ok {
		code, phase := metadata.DiagnosticCode(), metadata.DiagnosticPhase()
		if code != "" && phase != "" {
			return newError(code, phase, err)
		}
	}
	if errors.Is(err, platform.ErrParse) {
		return newError("unrecognized_output", fallbackPhase, err)
	}
	return err
}

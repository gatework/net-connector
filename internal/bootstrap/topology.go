package bootstrap

import (
	"regexp"
	"strings"

	"github.com/gatework/net-connector/netdisco"

	"github.com/gatework/net-connector/config"
)

var topologyPrefix = regexp.MustCompile(`^[\pL\pN_.-]+$`)

// ValidateTopology validates public topology policy without resolving credentials.
func ValidateTopology(p config.Snapshot, requested string) error {
	mode, _ := p.Value("topology.mode").(string)
	if _, err := resolveTopologyMode(mode, requested); err != nil {
		return err
	}
	format, _ := p.Value("topology.description_format").(string)
	if strings.ContainsAny(format, "\r\n\x00") || strings.Contains(strings.ReplaceAll(strings.ReplaceAll(format, "%{neighbor}", ""), "%{port}", ""), "%") {
		return config.ErrInvalid
	}
	if values, ok := p.Value("topology.neighbor_name_prefixes").([]any); ok {
		for _, v := range values {
			prefix, ok := v.(string)
			if !ok || !topologyPrefix.MatchString(prefix) {
				return config.ErrInvalid
			}
		}
	}
	if cacheMode, ok := p.Value("topology.cache_mode").(string); ok && !netdisco.CacheMode(cacheMode).Valid() {
		return config.ErrInvalid
	}
	return nil
}

func resolveTopologyMode(configured, requested string) (string, error) {
	if configured == "" {
		configured = "plan"
	}
	switch requested {
	case "":
	case "plan", "discover", "apply":
		configured = requested
	default:
		return "", config.ErrInvalid
	}
	if configured == "apply" && requested != "apply" || configured != "plan" && configured != "discover" && configured != "apply" {
		return "", config.ErrInvalid
	}
	return configured, nil
}

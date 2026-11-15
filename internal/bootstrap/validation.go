package bootstrap

import (
	"net/url"
	"strings"

	"github.com/gatework/net-connector/config"
	"github.com/gatework/net-connector/netdisco"
)

func (s *Services) validatePolicy() error {
	p := s.policy
	for _, key := range []string{"page_size", "max_pages", "max_devices", "max_response_bytes", "max_inventory_bytes"} {
		if v := p.Value("netdisco." + key); v != nil {
			n, ok := v.(int)
			if !ok || n < 1 {
				return config.ErrInvalid
			}
		}
	}
	if v := p.Value("netdisco.inventory_timeout"); v != nil && durationValue(p, "netdisco.inventory_timeout") <= 0 {
		return config.ErrInvalid
	}
	if durationValue(p, "netdisco.cache_ttl") < 0 {
		return config.ErrInvalid
	}
	if p.Value("topology.parallel") != nil {
		if n := integerValue(p, "topology.parallel"); n < 1 || n > 500 {
			return config.ErrInvalid
		}
	}
	if n := integerValue(p, "topology.limit"); n < 0 {
		return config.ErrInvalid
	}
	if err := s.validateInventorySource(); err != nil {
		return err
	}
	if n := integerValue(p, "netdisco.db_port"); n < 1 || n > 65535 {
		return config.ErrInvalid
	}
	if n := integerValue(p, "netdisco.db_connect_timeout"); n < 1 {
		return config.ErrInvalid
	}
	mode := stringValue(p, "netdisco.db_sslmode")
	if mode != "" && !strings.Contains("|disable|allow|prefer|require|verify-ca|verify-full|", "|"+mode+"|") {
		return config.ErrInvalid
	}
	return nil
}

func (s *Services) validateInventorySource() error {
	p := s.policy
	switch stringValue(p, "inventory.source") {
	case "file":
		// A file inventory must not be mixed with a Netdisco endpoint: the
		// operator could not tell which one a run used.
		if stringValue(p, "inventory.file") == "" {
			return &config.FieldError{Field: "inventory.file", Problem: "required"}
		}
		if stringValue(p, "netdisco.url") != "" || p.Value("netdisco.query") != nil {
			return &config.FieldError{Field: "inventory.source", Problem: "conflicts with netdisco settings"}
		}
		return nil
	case "netdisco":
	default:
		return &config.FieldError{Field: "inventory.source", Problem: "invalid"}
	}
	switch stringValue(p, "netdisco.source") {
	case "http":
		if p.Value("netdisco.query") != nil || p.Value("netdisco.query_params") != nil {
			return config.ErrInvalid
		}
		if raw := stringValue(p, "netdisco.url"); raw != "" {
			u, e := url.Parse(raw)
			if e != nil || u.Host == "" || u.User != nil || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || u.Scheme != "https" && !(u.Scheme == "http" && boolValue(p, "netdisco.allow_insecure_http")) {
				return config.ErrInvalid
			}
		}
	case "postgres":
		params, _ := p.Value("netdisco.query_params").([]any)
		if _, e := netdisco.NewPostgres(netdisco.PostgresOptions{Connection: "host=localhost user=preflight dbname=preflight sslmode=disable", Query: stringValue(p, "netdisco.query"), Parameters: params, Limits: s.limits()}); e != nil {
			return e
		}
	default:
		return config.ErrInvalid
	}
	return nil
}

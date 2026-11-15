package bootstrap

import (
	"path/filepath"
	"strings"

	"github.com/gatework/net-connector/config"
	"github.com/gatework/net-connector/vendors"
)

// ValidateTFTP checks local requirements without reading credentials or opening a connection.
func ValidateTFTP(snapshot config.Snapshot, successPolicy string) error {
	settings, err := resolveSettings(snapshot)
	if err != nil {
		return err
	}
	s := &Services{policy: snapshot, settings: settings, registry: vendors.NewBuiltinRegistry()}
	if _, err := s.TFTPPolicy(); err != nil {
		return err
	}
	servers, err := stringMap(snapshot, "tftp.servers")
	if err != nil {
		return err
	}
	roots, err := stringMap(snapshot, "tftp.verification_roots")
	if err != nil {
		return err
	}
	server := stringValue(snapshot, "tftp.server")
	if server == "" && len(servers) == 0 {
		return &config.FieldError{Field: "tftp.server", Problem: "required"}
	}
	if successPolicy == "verified" {
		available := map[string]string{}
		for key, value := range roots {
			available[strings.ToLower(key)] = value
		}
		if root := stringValue(snapshot, "tftp.verification_root"); root != "" && server != "" {
			available[strings.ToLower(server)] = root
		}
		if server != "" && available[strings.ToLower(server)] == "" {
			return &config.FieldError{Field: "tftp.verification_root", Problem: "required"}
		}
		for _, target := range servers {
			if available[strings.ToLower(target)] == "" {
				return &config.FieldError{Field: "tftp.verification_roots", Problem: "required"}
			}
		}
	}
	worker := stringValue(snapshot, "tftp.ssh_worker_path")
	if worker != "" && (!filepath.IsAbs(worker) || filepath.Clean(worker) != worker || strings.ContainsAny(worker, "\x00\r\n")) {
		return &config.FieldError{Field: "tftp.ssh_worker_path", Problem: "invalid"}
	}
	if s.ArchiveTimeouts().Upload <= 0 {
		return &config.FieldError{Field: "tftp.upload_timeout", Problem: "invalid"}
	}
	return nil
}

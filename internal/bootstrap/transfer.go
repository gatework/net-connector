package bootstrap

import (
	"github.com/gatework/net-connector/archive"
	"github.com/gatework/net-connector/config"
	"github.com/gatework/net-connector/transfer"
)

// TFTPPolicy returns the validated platform transfer policy.
func (s *Services) TFTPPolicy() (*transfer.Policy, error) {
	if s.tftpPolicy != nil {
		return s.tftpPolicy, nil
	}
	return s.buildTFTPPolicy()
}

func (s *Services) buildTFTPPolicy() (*transfer.Policy, error) {
	p := s.policy
	servers, e := stringMap(p, "tftp.servers")
	if e != nil {
		return nil, e
	}
	roots, e := stringMap(p, "tftp.verification_roots")
	if e != nil {
		return nil, e
	}
	get := func(key string) (map[string]any, error) {
		v := p.Value(key)
		if v == nil {
			return map[string]any{}, nil
		}
		m, ok := v.(map[string]any)
		if !ok {
			return nil, config.ErrInvalid
		}
		return m, nil
	}
	files, e := get("tftp.source_files")
	if e != nil {
		return nil, e
	}
	interfaces, e := get("tftp.source_interfaces")
	if e != nil {
		return nil, e
	}
	vrfs, e := get("tftp.vrfs")
	if e != nil {
		return nil, e
	}
	return transfer.NewPolicy(transfer.PolicyOptions{Server: stringValue(p, "tftp.server"), Root: stringValue(p, "tftp.verification_root"), Servers: servers, Roots: roots, SourceFiles: files, SourceInterfaces: interfaces, VRFs: vrfs}, s.registry)
}

// ArchivePassword resolves the archive credential only during online preparation.
func (s *Services) ArchivePassword() string { return s.secret("NC_TFTP_SSH_PASSWORD") }

// ArchiveTimeouts returns the archive phase timeout budgets.
func (s *Services) ArchiveTimeouts() archive.Timeouts { return s.settings.archiveTimeouts }

// RemoteBackupPassword resolves the remote export credential only when a
// remote backup actually runs; it is never logged or written to a report.
func (s *Services) RemoteBackupPassword() string { return s.secret("NC_REMOTE_BACKUP_PASSWORD") }

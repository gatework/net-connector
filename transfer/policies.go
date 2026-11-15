package transfer

import (
	"github.com/gatework/net-connector/connector"
)

// TFTPPolicy is the device-specific half of a TFTP operation. Shared target
// grammar, service verification and archive lifecycle stay in transfer.
type TFTPPolicy interface {
	// Traits returns the platform's fixed transfer requirements.
	Traits() TFTPTraits
	ValidateOptions(deviceHost string, options TFTPOptions) error
	Filename(host, label string) (string, error)
	Command(deviceHost string, options TFTPOptions, explicitPath bool) connector.Command
	Completed(lines []string, options TFTPOptions) (actualPath string, complete bool, err error)
	Evidence(options TFTPOptions, explicitSource, explicitPath bool) TFTPEvidence
}

// TFTPTraits are the fixed transfer requirements a platform declares.
type TFTPTraits struct {
	// DefaultVRF is the routing instance used when none is configured.
	DefaultVRF string
	// ReuseDestination allows several devices to upload to one fixed remote name.
	ReuseDestination bool
	// RequireSourceFile demands an explicitly configured source file.
	RequireSourceFile bool
	// RequireVerificationRoot makes server-side archive verification mandatory.
	RequireVerificationRoot bool
}

// SourceFileResolver is an optional TFTPPolicy capability for platforms that
// can ask the device which saved configuration file to upload.
type SourceFileResolver interface {
	SourceFileCommand() string
	ResolveSourceFile(output string) (string, error)
}

// RemoteBackupPolicy defines a platform's native remote configuration export.
type RemoteBackupPolicy interface {
	Destination(options RemoteBackupOptions) string
	Command(options RemoteBackupOptions, password string) connector.Command
	Completed(lines []string, destination string) bool
}

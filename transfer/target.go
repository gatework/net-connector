package transfer

import (
	"errors"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/platform"
)

// Named source interfaces accepted by platforms that distinguish their
// management and data planes instead of taking a device interface name.
const (
	SourceInterfaceManagement = "management"
	SourceInterfaceData       = "data"
)

// TFTPOptions contains a platform-independent TFTP transfer request.
type TFTPOptions struct {
	Server, Path, SourceFile, VRF, SourceInterface string
	Timeout                                        time.Duration
}

// TFTPEvidence describes the configuration format and requested-path evidence
// a platform attaches to an upload.
type TFTPEvidence struct {
	ConfigurationKind, Format, SourceFile string
	IncludeRequestedPath                  bool
}

// RemoteBackupOptions carries options for a platform's native remote export.
type RemoteBackupOptions struct {
	Server, Path, Username, Protocol string
}

var filenameLabel = regexp.MustCompile(`[^A-Za-z0-9._-]+`)
var serverPattern = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$`)
var pathPattern = regexp.MustCompile(`^[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*$`)
var sourcePattern = regexp.MustCompile(`^[A-Za-z0-9._:/-]+$`)
var vrfPattern = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.-]*$`)

// ValidateServer checks a server name accepted by transfer command rendering.
func ValidateServer(host string) error {
	if len(host) > 253 || !serverPattern.MatchString(host) || strings.Contains(host, "..") {
		return ErrInvalid
	}
	return nil
}

// ValidatePath checks a bounded transfer path and rejects traversal components.
func ValidatePath(path string) error {
	if len(path) > 220 || !pathPattern.MatchString(path) {
		return ErrInvalid
	}
	for part := range strings.SplitSeq(path, "/") {
		if part == "." || part == ".." {
			return ErrInvalid
		}
	}
	return nil
}

// ValidateSource checks a device source filename and rejects traversal components.
func ValidateSource(source string) error {
	if !sourcePattern.MatchString(source) {
		return ErrInvalid
	}
	if slices.Contains(strings.Split(source, "/"), "..") {
		return ErrInvalid
	}
	return nil
}

// Validate checks common and platform-specific TFTP options without I/O.
func Validate(registry platform.Registry, vendor, deviceHost string, o TFTPOptions) error {
	if o.Timeout < 0 {
		return ErrInvalid
	}
	if registry == nil {
		return ErrUnsupported
	}
	d, e := registry.Lookup(vendor)
	if e != nil {
		return ErrUnsupported
	}
	tftp, ok := d.(TFTPPolicy)
	if !ok {
		return ErrUnsupported
	}
	if ValidateServer(o.Server) != nil || o.Path != "" && ValidatePath(o.Path) != nil || o.SourceFile != "" && ValidateSource(o.SourceFile) != nil || o.VRF != "" && !vrfPattern.MatchString(o.VRF) {
		return ErrInvalid
	}
	if tftp.Traits().RequireSourceFile && o.SourceFile == "" {
		return errors.Join(ErrInvalid, ErrSourceFileRequired)
	}
	if err := tftp.ValidateOptions(deviceHost, o); err != nil {
		if errors.Is(err, connector.ErrUnsupported) {
			return ErrUnsupported
		}
		return ErrInvalid
	}
	return nil
}

// Filename obtains and validates the platform-specific destination filename.
func Filename(registry platform.Registry, vendor, host, label string) (string, error) {
	if registry == nil {
		return "", ErrUnsupported
	}
	d, e := registry.Lookup(vendor)
	if e != nil {
		return "", ErrUnsupported
	}
	tftp, ok := d.(TFTPPolicy)
	if !ok {
		return "", ErrUnsupported
	}
	name, err := tftp.Filename(host, label)
	if err != nil || ValidatePath(name) != nil {
		return "", ErrInvalid
	}
	return name, nil
}

// InventoryFilename derives a bounded label from an inventory name.
func InventoryFilename(registry platform.Registry, vendor, host, name string) (string, error) {
	label := filenameLabel.ReplaceAllString(name, "-")
	if len(label) > 180 {
		label = label[:180]
	}
	label = strings.Trim(label, "._-")
	if label == "" {
		label = vendor
		if label == "" {
			label = "device"
		}
	}
	return Filename(registry, vendor, host, label)
}

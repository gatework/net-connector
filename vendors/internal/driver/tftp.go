package driver

import (
	"crypto/sha256"
	"fmt"
	"regexp"
	"slices"
	"strings"
	"time"

	expect "github.com/gatework/go-expect"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/transfer"
)

// TFTPOptions declares a platform's fixed transfer rules.
type TFTPOptions struct {
	Extension, Kind, Format, FixedPath, DefaultVRF string
	AcceptSourceFile, RequireSourceFile            bool
	AcceptVRF, FlatPath                            bool
	AllowDestinationReuse, RequireVerificationRoot bool
	ValidateSourceInterface                        func(deviceHost, sourceInterface string) error
}

// TFTPBase implements transfer validation and common filename/receipt rules.
type TFTPBase struct{ options TFTPOptions }

// NewTFTPBase constructs the shared portion of a platform's transfer policy.
func NewTFTPBase(options TFTPOptions) TFTPBase { return TFTPBase{options: options} }

// Remote filename limits keep generated names within the shortest path limit
// accepted by the supported device TFTP clients.
const (
	maxFilenameLength = 220
	maxSuffixLength   = maxFilenameLength - 2 // leaves room for a label and "-".
)

var (
	deviceFilePattern      = regexp.MustCompile(`^[A-Za-z0-9._:/-]+$`)
	deviceInterfacePattern = regexp.MustCompile(`^([A-Za-z][A-Za-z-]*) ?([0-9][0-9/.:]*)$`)
	deviceVRFPattern       = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.-]*$`)
	deviceFilenameAddress  = regexp.MustCompile(`[^A-Za-z0-9._-]`)
	fileCompletion         = []*regexp.Regexp{
		regexp.MustCompile(`(?i)^(?:File\s+)?(?:transfer(?:red)?|upload(?:ed)?)(?:\s+(?:is|was))?\s+(?:success(?:ful(?:ly)?)?|succeeded|complete(?:d)?(?:\s+successfully)?)[.!]?$`),
		regexp.MustCompile(`(?i)^(?:TFTP:\s*)?[1-9]\d*\s+bytes?\s+sent(?:\s+in\s+[\d.]+\s+(?:secs?|seconds?|second\(s\)))?[.!]?$`),
	}
	fileProgress = regexp.MustCompile(`(?i)^100\s+([1-9]\d*(?:\.\d+)?[kMGT]?)\s+0\s+0\s+100\s+([1-9]\d*(?:\.\d+)?[kMGT]?)(?:\s+[\d.:kMGT-]+)*$`)
)

// ParseDeviceInterface separates a conventional interface type and number.
func ParseDeviceInterface(value string) (kind, number string, ok bool) {
	match := deviceInterfacePattern.FindStringSubmatch(value)
	if len(match) != 3 {
		return "", "", false
	}
	return match[1], match[2], true
}

// ValidateManagementOrDataSource accepts the two named source interfaces used
// by platforms that distinguish management and data planes.
func ValidateManagementOrDataSource(_ string, source string) error {
	if source != transfer.SourceInterfaceManagement && source != transfer.SourceInterfaceData {
		return invalidOption("source interface")
	}
	return nil
}

// invalidOption names the rejected option without echoing its value.
func invalidOption(name string) error {
	return fmt.Errorf("%w: tftp %s", connector.ErrInvalid, name)
}

// ValidateOptions checks the source, VRF and destination constraints declared
// by a platform before any device command is sent.
func (b TFTPBase) ValidateOptions(deviceHost string, options transfer.TFTPOptions) error {
	o := b.options
	if options.SourceFile != "" && (!o.AcceptSourceFile || !deviceFilePattern.MatchString(options.SourceFile) || strings.Contains(options.SourceFile, "..")) {
		return invalidOption("source file")
	}
	if o.RequireSourceFile && options.SourceFile == "" {
		return invalidOption("source file")
	}
	if options.VRF != "" && (!o.AcceptVRF || !deviceVRFPattern.MatchString(options.VRF)) {
		return invalidOption("vrf")
	}
	if o.FlatPath && strings.Contains(options.Path, "/") {
		return invalidOption("path")
	}
	if o.FixedPath != "" && options.Path != "" && options.Path != o.FixedPath {
		return invalidOption("path")
	}
	if options.SourceInterface == "" {
		return nil
	}
	if o.ValidateSourceInterface == nil {
		return invalidOption("source interface")
	}
	return o.ValidateSourceInterface(deviceHost, options.SourceInterface)
}

// Traits returns the platform's fixed transfer requirements.
func (b TFTPBase) Traits() transfer.TFTPTraits {
	return transfer.TFTPTraits{
		DefaultVRF:              b.options.DefaultVRF,
		ReuseDestination:        b.options.AllowDestinationReuse,
		RequireSourceFile:       b.options.RequireSourceFile,
		RequireVerificationRoot: b.options.RequireVerificationRoot,
	}
}

// Filename returns a safe default remote filename for this platform.
func (b TFTPBase) Filename(host, label string) (string, error) {
	if b.options.FixedPath != "" {
		return b.options.FixedPath, nil
	}
	address := deviceFilenameAddress.ReplaceAllString(host, "_")
	suffix := address + "." + b.options.Extension
	if len(suffix) > maxSuffixLength {
		suffix = fmt.Sprintf("%x.%s", sha256.Sum256([]byte(host)), b.options.Extension)
	}
	name := suffix
	if label != "" {
		for _, character := range label {
			if character > 127 {
				return "", invalidOption("label")
			}
		}
		if maximum := maxFilenameLength - len(suffix) - 1; len(label) > maximum {
			label = label[:maximum]
		}
		name = label + "-" + suffix
	}
	return name, nil
}

// Evidence returns the common archive metadata for this platform.
func (b TFTPBase) Evidence(options transfer.TFTPOptions, explicitSource, _ bool) transfer.TFTPEvidence {
	receipt := transfer.TFTPEvidence{ConfigurationKind: b.options.Kind, Format: b.options.Format, SourceFile: options.SourceFile, IncludeRequestedPath: true}
	if explicitSource && b.options.AcceptSourceFile {
		receipt.ConfigurationKind = "saved_file"
	}
	return receipt
}

// CommandWithTimeout applies a per-operation timeout when one is configured.
func CommandWithTimeout(text string, timeout time.Duration) connector.Command {
	command := connector.Command{Text: text}
	command.Timeout = TimeoutPointer(timeout)
	return command
}

// TimeoutPointer returns nil for an unspecified timeout.
func TimeoutPointer(timeout time.Duration) *time.Duration {
	if timeout <= 0 {
		return nil
	}
	return &timeout
}

// TransferReply compiles a TFTP prompt and its automatic response.
func TransferReply(expression, response string) connector.Interaction {
	pattern, err := expect.Compile(expression)
	if err != nil {
		panic(err)
	}
	return connector.Interaction{Pattern: pattern, Reply: response, Unlimited: true}
}

// AnyMatch reports whether any response line matches a compiled completion rule.
func AnyMatch(lines []string, pattern *regexp.Regexp) bool {
	return slices.ContainsFunc(lines, pattern.MatchString)
}

// FileTransferred recognizes generic positive byte-count and completion output.
func FileTransferred(lines []string) bool {
	for _, line := range lines {
		for _, pattern := range fileCompletion {
			if pattern.MatchString(line) {
				return true
			}
		}
		if match := fileProgress.FindStringSubmatch(line); match != nil && match[1] == match[2] {
			return true
		}
	}
	return false
}

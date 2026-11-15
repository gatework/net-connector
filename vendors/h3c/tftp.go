package h3c

import (
	"net/netip"
	"regexp"
	"strings"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/transfer"
	"github.com/gatework/net-connector/vendors/internal/driver"
)

var (
	startupNext    = regexp.MustCompile(`(?mi)^\s*Next main startup saved-configuration file:\s*(\S+)`)
	startupCurrent = regexp.MustCompile(`(?mi)^\s*Current startup saved-configuration file:\s*(\S+)`)
)

func validateSourceInterface(deviceHost, source string) error {
	if source == "management" {
		address, err := netip.ParseAddr(deviceHost)
		if err != nil || !address.Is4() {
			return connector.ErrInvalid
		}
		return nil
	}
	if _, _, ok := driver.ParseDeviceInterface(source); !ok {
		return connector.ErrInvalid
	}
	return nil
}

type tftpPolicy struct{ driver.TFTPBase }

func newTFTPPolicy() tftpPolicy {
	return tftpPolicy{driver.NewTFTPBase(driver.TFTPOptions{Extension: "cfg", Kind: "startup", Format: "unknown", AcceptSourceFile: true, ValidateSourceInterface: validateSourceInterface})}
}
func (tftpPolicy) SourceFileCommand() string { return "display startup" }
func (tftpPolicy) ResolveSourceFile(output string) (string, error) {
	match := startupNext.FindStringSubmatch(output)
	if match == nil {
		match = startupCurrent.FindStringSubmatch(output)
	}
	if match == nil || strings.EqualFold(match[1], "NULL") {
		return "", platform.ErrParse
	}
	return strings.TrimSuffix(match[1], "(*)"), nil
}
func (h tftpPolicy) Command(host string, o transfer.TFTPOptions, explicitPath bool) connector.Command {
	command := "tftp " + o.Server + " put " + o.SourceFile
	if explicitPath {
		command += " " + o.Path
	}
	if o.SourceInterface == "management" {
		command += " source ip " + host
	} else if o.SourceInterface != "" {
		kind, number, _ := driver.ParseDeviceInterface(o.SourceInterface)
		command += " source interface " + kind + " " + number
	}
	return driver.CommandWithTimeout(command, o.Timeout)
}
func (tftpPolicy) Completed(lines []string, _ transfer.TFTPOptions) (string, bool, error) {
	return "", driver.FileTransferred(lines), nil
}

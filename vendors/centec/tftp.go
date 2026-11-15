package centec

import (
	"regexp"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/transfer"
	"github.com/gatework/net-connector/vendors/internal/driver"
)

var completionPattern = regexp.MustCompile(`(?i)^Sent\s+[1-9]\d*\s+bytes\s+in\s+[\d.]+\s+seconds?[.!]?$`)

type tftpPolicy struct{ driver.TFTPBase }

func newTFTPPolicy() tftpPolicy {
	return tftpPolicy{driver.NewTFTPBase(driver.TFTPOptions{Extension: "cfg", Kind: "running", Format: "cfg", ValidateSourceInterface: driver.ValidateManagementOrDataSource})}
}
func (c tftpPolicy) Command(_ string, o transfer.TFTPOptions, _ bool) connector.Command {
	command := "copy running-config"
	if o.SourceInterface == "management" {
		command += " mgmt-if"
	}
	command += " tftp://" + o.Server + "/" + o.Path
	return driver.CommandWithTimeout(command, o.Timeout)
}
func (tftpPolicy) Completed(lines []string, _ transfer.TFTPOptions) (string, bool, error) {
	return "", driver.AnyMatch(lines, completionPattern), nil
}

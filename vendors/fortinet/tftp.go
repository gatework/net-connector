package fortinet

import (
	"regexp"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/transfer"
	"github.com/gatework/net-connector/vendors/internal/driver"
)

var completionPattern = regexp.MustCompile(`(?i)^Send config file to tftp server OK\.?$`)

type tftpPolicy struct{ driver.TFTPBase }

func newTFTPPolicy() tftpPolicy {
	return tftpPolicy{driver.NewTFTPBase(driver.TFTPOptions{Extension: "cfg", Kind: "running", Format: "cfg"})}
}
func (f tftpPolicy) Command(_ string, o transfer.TFTPOptions, _ bool) connector.Command {
	return driver.CommandWithTimeout("execute backup full-config tftp "+o.Path+" "+o.Server, o.Timeout)
}
func (tftpPolicy) Completed(lines []string, _ transfer.TFTPOptions) (string, bool, error) {
	return "", driver.AnyMatch(lines, completionPattern), nil
}

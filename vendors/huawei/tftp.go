package huawei

import (
	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/transfer"
	"github.com/gatework/net-connector/vendors/internal/driver"
)

type tftpPolicy struct{ driver.TFTPBase }

func newTFTPPolicy() tftpPolicy {
	return tftpPolicy{driver.NewTFTPBase(driver.TFTPOptions{Extension: "cfg", Kind: "saved_file", Format: "unknown", AcceptSourceFile: true, RequireSourceFile: true})}
}
func (h tftpPolicy) Command(_ string, o transfer.TFTPOptions, explicitPath bool) connector.Command {
	command := "tftp " + o.Server + " put " + o.SourceFile
	if explicitPath {
		command += " " + o.Path
	}
	return driver.CommandWithTimeout(command, o.Timeout)
}
func (tftpPolicy) Completed(lines []string, _ transfer.TFTPOptions) (string, bool, error) {
	return "", driver.FileTransferred(lines), nil
}

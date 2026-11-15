package hillstone

import (
	"regexp"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/transfer"
	"github.com/gatework/net-connector/vendors/internal/driver"
)

var exportPattern = regexp.MustCompile(`(?i)^Export\s+ok\s*,\s*target\s+file\s+name\s+(\S+)$`)

type tftpPolicy struct{ driver.TFTPBase }

func newTFTPPolicy() tftpPolicy {
	return tftpPolicy{driver.NewTFTPBase(driver.TFTPOptions{Extension: "dat", Kind: "startup", Format: "dat", DefaultVRF: "mgt-vr", AcceptVRF: true, FlatPath: true})}
}
func (h tftpPolicy) Command(_ string, o transfer.TFTPOptions, explicitPath bool) connector.Command {
	vrf := o.VRF
	if vrf == "" {
		vrf = h.Traits().DefaultVRF
	}
	command := "export configuration startup to tftp server " + o.Server + " vrouter " + vrf
	if explicitPath {
		command += " " + o.Path
	}
	return driver.CommandWithTimeout(command, o.Timeout)
}
func (tftpPolicy) Completed(lines []string, _ transfer.TFTPOptions) (string, bool, error) {
	for _, line := range lines {
		if match := exportPattern.FindStringSubmatch(line); match != nil {
			return match[1], true, nil
		}
	}
	return "", false, nil
}
func (tftpPolicy) Evidence(o transfer.TFTPOptions, explicitSource, explicitPath bool) transfer.TFTPEvidence {
	receipt := driver.NewTFTPBase(driver.TFTPOptions{Kind: "startup", Format: "dat", Extension: "dat"}).Evidence(o, explicitSource, explicitPath)
	receipt.IncludeRequestedPath = explicitPath
	return receipt
}

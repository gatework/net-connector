package radware

import (
	"regexp"
	"strings"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/transfer"
	"github.com/gatework/net-connector/vendors/internal/driver"
)

var transferReceiptPattern = regexp.MustCompile(`(?i)^Current\s+config\s+successfully\s+transferred\s+to\s+([^\s:]+):(\S+)$`)

type tftpPolicy struct{ driver.TFTPBase }

func newTFTPPolicy() tftpPolicy {
	return tftpPolicy{driver.NewTFTPBase(driver.TFTPOptions{Extension: "tgz", Kind: "native_archive", Format: "tgz", ValidateSourceInterface: driver.ValidateManagementOrDataSource})}
}
func (r tftpPolicy) Command(_ string, o transfer.TFTPOptions, _ bool) connector.Command {
	command := "/cfg/ptcfg " + o.Server + " -tftp"
	switch o.SourceInterface {
	case "management":
		command += " -mgmt"
	case "data":
		command += " -data"
	}
	commandInteractions := []connector.Interaction{
		driver.TransferReply(`(?i)Enter\s+(?:hostname|IP address)[^\r\n]*:\s*$`, o.Server+"\n"),
		driver.TransferReply(`(?i)Enter\s+name\s+of\s+(?:\.tgz\s+)?file[^\r\n]*:\s*$`, o.Path+"\n"),
		driver.TransferReply(`(?i)Enter\s+username[^\r\n]*:\s*$`, "\n"),
		driver.TransferReply(`(?i)Include\s+private\s+keys\?\s*\[y/n\]:\s*$`, "n\n"),
		driver.TransferReply(`(?i)Enter\s+"?mansync"?\s+to\s+get\s+real/group/virt\s+internal\s+index\s+config:\s*$`, "mansync\n"),
	}
	return connector.Command{Text: command, Interactions: commandInteractions, Timeout: driver.TimeoutPointer(o.Timeout)}
}
func (tftpPolicy) Completed(lines []string, o transfer.TFTPOptions) (string, bool, error) {
	found := map[string]bool{}
	actual := ""
	for _, line := range lines {
		match := transferReceiptPattern.FindStringSubmatch(line)
		if match == nil {
			continue
		}
		found[strings.ToLower(match[1])+":"+match[2]] = true
		if !strings.EqualFold(match[1], o.Server) {
			return "", false, platform.ErrParse
		}
		actual = match[2]
	}
	if len(found) > 1 {
		return "", false, platform.ErrParse
	}
	return actual, actual != "", nil
}

func (tftpPolicy) Evidence(_ transfer.TFTPOptions, _, explicitPath bool) transfer.TFTPEvidence {
	return transfer.TFTPEvidence{ConfigurationKind: "native_archive", Format: "tgz", IncludeRequestedPath: true}
}

package cisco

import (
	"regexp"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/transfer"
	"github.com/gatework/net-connector/vendors/internal/driver"
)

var (
	copiedPattern       = regexp.MustCompile(`(?i)^[1-9]\d*\s+bytes?\s+copied(?:\s+in\s+[\d.]+\s+(?:secs?|seconds?)(?:\s+\([\d.]+\s+bytes/sec\))?)?[.!]?$`)
	iosSuccessPattern   = regexp.MustCompile(`(?i)^\[OK(?:\s*-\s*[1-9]\d*\s+bytes)?\]$`)
	nxosTransferPattern = regexp.MustCompile(`(?i)^(?:transfer|copy)(?:\s+operation)?\s+(?:success(?:ful(?:ly)?)?|succeeded|complete(?:d)?(?:\s+successfully)?)[.!]?$`)
)

type iosTFTPPolicy struct{ driver.TFTPBase }

func newIOSTFTPPolicy() iosTFTPPolicy {
	return iosTFTPPolicy{driver.NewTFTPBase(driver.TFTPOptions{Extension: "cfg", Kind: "running", Format: "cfg"})}
}
func (c iosTFTPPolicy) Command(_ string, o transfer.TFTPOptions, _ bool) connector.Command {
	command := connector.Command{Text: "copy running-config tftp:"}
	command.Interactions = []connector.Interaction{driver.TransferReply(`(?i)Address\s+or\s+name\s+of\s+remote\s+host\s*\[[^\]]*\]\?\s*$`, o.Server+"\n"), driver.TransferReply(`(?i)Destination\s+filename\s*\[[^\]]*\]\?\s*$`, o.Path+"\n")}
	command.Timeout = driver.TimeoutPointer(o.Timeout)
	return command
}
func (iosTFTPPolicy) Completed(lines []string, _ transfer.TFTPOptions) (string, bool, error) {
	for _, line := range lines {
		if copiedPattern.MatchString(line) || iosSuccessPattern.MatchString(line) {
			return "", true, nil
		}
	}
	return "", false, nil
}

type nxosTFTPPolicy struct{ driver.TFTPBase }

func newNXOSTFTPPolicy() nxosTFTPPolicy {
	return nxosTFTPPolicy{driver.NewTFTPBase(driver.TFTPOptions{Extension: "cfg", Kind: "running", Format: "cfg", DefaultVRF: "management", AcceptVRF: true})}
}
func (n nxosTFTPPolicy) Command(_ string, o transfer.TFTPOptions, _ bool) connector.Command {
	vrf := o.VRF
	if vrf == "" {
		vrf = n.Traits().DefaultVRF
	}
	command := connector.Command{Text: "copy running-config tftp://" + o.Server + "/" + o.Path + " vrf " + vrf}
	command.Interactions = []connector.Interaction{driver.TransferReply(`(?i)Enter\s+vrf\s*\([^\r\n]*\):\s*$`, vrf+"\n")}
	command.Timeout = driver.TimeoutPointer(o.Timeout)
	return command
}
func (nxosTFTPPolicy) Completed(lines []string, _ transfer.TFTPOptions) (string, bool, error) {
	for _, line := range lines {
		if copiedPattern.MatchString(line) || nxosTransferPattern.MatchString(line) {
			return "", true, nil
		}
	}
	return "", false, nil
}

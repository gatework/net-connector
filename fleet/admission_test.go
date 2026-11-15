package fleet

import (
	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/transfer"
)

// admitConfig admits platforms that can collect a configuration, as the
// backup operation does.
func admitConfig(_ Record, p platform.Platform) string {
	if !connector.CanCollectConfig(p) {
		return "unsupported_operation"
	}
	return ""
}

// admitTFTP admits platforms with a TFTP policy, as the TFTP operation does.
func admitTFTP(_ Record, p platform.Platform) string {
	if _, ok := p.(transfer.TFTPPolicy); !ok {
		return "unsupported_operation"
	}
	return ""
}

func reuseTFTP(p platform.Platform) bool {
	policy, ok := p.(transfer.TFTPPolicy)
	return ok && policy.Traits().ReuseDestination
}

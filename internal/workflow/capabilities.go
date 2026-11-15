package workflow

import (
	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/facts"
	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/topology"
	"github.com/gatework/net-connector/transfer"
)

// Capabilities lists what one platform declares. Each field mirrors the
// admission check of the stage that needs it, so the listing cannot drift
// from what a batch would actually admit. Declared support is not evidence
// of real-device compatibility.
type Capabilities struct {
	Platform          string `json:"platform"`
	ConfigCollection  bool   `json:"config_collection"`
	Save              bool   `json:"save"`
	Commit            bool   `json:"commit"`
	ReadOnlyCommands  bool   `json:"read_only_commands"`
	Facts             bool   `json:"facts"`
	NeighborDiscovery bool   `json:"neighbor_discovery"`
	DescriptionRead   bool   `json:"description_read"`
	InterfaceIdentity bool   `json:"interface_identity"`
	DescriptionWrite  bool   `json:"description_write"`
	TFTP              bool   `json:"tftp"`
	RemoteBackup      bool   `json:"remote_backup"`
}

// CapabilitiesOf reports the capabilities p declares.
func CapabilitiesOf(p platform.Platform) Capabilities {
	c := Capabilities{Platform: p.Name(), ConfigCollection: connector.CanCollectConfig(p), Save: connector.CanSave(p)}
	_, c.Commit = connector.AsCommitter(p)
	_, c.ReadOnlyCommands = p.(ReadOnlyClassifier)
	_, factsErr := facts.Commands(p)
	c.Facts = factsErr == nil
	_, c.NeighborDiscovery = p.(topology.NeighborDiscovery)
	_, c.DescriptionRead = p.(topology.DescriptionReader)
	_, c.InterfaceIdentity = p.(topology.InterfaceIdentity)
	_, c.DescriptionWrite = p.(topology.DescriptionWriter)
	_, c.TFTP = p.(transfer.TFTPPolicy)
	_, c.RemoteBackup = p.(transfer.RemoteBackupPolicy)
	return c
}

// PlatformCapabilities lists every registered platform in key order.
func PlatformCapabilities(registry platform.Registry) ([]Capabilities, error) {
	names := registry.Names()
	out := make([]Capabilities, 0, len(names))
	for _, name := range names {
		p, err := registry.Lookup(name)
		if err != nil {
			return nil, err
		}
		out = append(out, CapabilitiesOf(p))
	}
	return out, nil
}

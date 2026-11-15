package bootstrap

import (
	"context"
	"io"

	"github.com/gatework/net-connector/config"
	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/fleet"
	"github.com/gatework/net-connector/internal/workflow"
)

// WorkflowRuntime assembles operation dependencies without opening a device.
func (s *Services) WorkflowRuntime() workflow.Runtime {
	return workflow.Runtime{
		Rules:        s.Rules(),
		Registry:     s.Registry(),
		Workers:      s.Workers(),
		Directory:    s.Directory(),
		LogDirectory: s.LogDirectory,
		OpenDevice: func(ctx context.Context, device fleet.Record, logger io.Writer, observer workflow.SessionObserver) (*connector.Device, error) {
			return s.WithSessionObserver(observer).DeviceWithLogger(ctx, device, logger)
		},
	}
}

// WorkflowTFTPSettings returns the validated archive and transfer settings.
func (s *Services) WorkflowTFTPSettings() (workflow.TFTPSettings, error) {
	policy, err := s.TFTPPolicy()
	if err != nil {
		return workflow.TFTPSettings{}, err
	}
	workerPath, _ := s.Policy().Value("tftp.ssh_worker_path").(string)
	return workflow.TFTPSettings{
		ArchiveTimeouts:   s.ArchiveTimeouts(),
		Policy:            policy,
		LimitPerPlatform:  s.Limit(),
		ArchiveWorkerPath: workerPath,
		ArchivePassword:   s.ArchivePassword,
	}, nil
}

// WorkflowTopologySettings resolves the explicit command against the saved policy.
func (s *Services) WorkflowTopologySettings(requested string) (workflow.TopologySettings, error) {
	policy := s.policy
	if err := ValidateTopology(policy, requested); err != nil {
		return workflow.TopologySettings{}, err
	}
	mode, err := resolveTopologyMode(stringValue(policy, "topology.mode"), requested)
	if err != nil {
		return workflow.TopologySettings{}, err
	}
	settings := workflow.TopologySettings{
		Mode:                 mode,
		Workers:              s.Workers(),
		Directory:            stringValue(policy, "topology.directory"),
		DescriptionFormat:    stringValue(policy, "topology.description_format"),
		AbbreviatePorts:      true,
		NeighborNamePrefixes: []string{},
	}
	if value, ok := policy.Value("topology.parallel").(int); ok {
		settings.Workers = value
	}
	if value, ok := policy.Value("topology.limit").(int); ok {
		settings.Limit = value
	}
	if value, ok := policy.Value("topology.abbreviate_ports").(bool); ok {
		settings.AbbreviatePorts = value
	}
	settings.LowercasePorts, _ = policy.Value("topology.lowercase_ports").(bool)
	if values, ok := policy.Value("topology.neighbor_name_prefixes").([]any); ok {
		for _, value := range values {
			prefix, ok := value.(string)
			if !ok {
				return workflow.TopologySettings{}, config.ErrInvalid
			}
			settings.NeighborNamePrefixes = append(settings.NeighborNamePrefixes, prefix)
		}
	}
	return settings, nil
}

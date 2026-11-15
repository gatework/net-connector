package bootstrap

import (
	"context"

	"github.com/gatework/net-connector/config"
	"github.com/gatework/net-connector/internal/batchreport"
	"github.com/gatework/net-connector/internal/workflow"
	"github.com/gatework/net-connector/netdisco"
)

// PolicyOptions describes the application input layer before configuration I/O.
// PublicOverrides contains flag-selected public environment names, not secrets.
type PolicyOptions struct {
	Mode, CWD, Home, Program, ConfigFile, EnvFile string
	Directories                                   []string
	Environment, PublicOverrides                  map[string]string
	AllowMissing                                  bool
}

// LoadPolicy selects command defaults and loads one immutable policy snapshot.
func LoadPolicy(ctx context.Context, o PolicyOptions) (config.Snapshot, error) {
	if err := ctx.Err(); err != nil {
		return config.Snapshot{}, err
	}
	overrides, err := config.FromEnvironment(o.PublicOverrides)
	if err != nil {
		return config.Snapshot{}, err
	}
	name := "backup"
	if o.Mode == "topology" {
		name = "topology"
	}
	return config.Load(ctx, config.Options{
		Name: name, CWD: o.CWD, Home: o.Home, Program: o.Program,
		Directories: o.Directories, ConfigFile: o.ConfigFile, EnvFile: o.EnvFile,
		Environment: o.Environment, Overrides: overrides, Defaults: config.Defaults(o.Mode),
		AllowMissing: o.AllowMissing,
	})
}

// BackupOptions resolves the backup policy and layout before any operation is
// admitted. Configuration inspection may describe a policy for another mode.
func BackupOptions(policy config.Snapshot, mode string, inspect bool) (workflow.BackupOptions, error) {
	options := workflow.BackupOptions{
		Policy: stringValue(policy, "backup.success_policy"),
		Layout: stringValue(policy, "backup.layout"),
	}
	policyValue := batchreport.SuccessPolicy(options.Policy)
	if !policyValue.Valid() || !inspect && !policyValue.AllowedFor(mode == "tftp") {
		return workflow.BackupOptions{}, &config.FieldError{Field: "backup.success_policy", Problem: "invalid"}
	}
	return options, nil
}

// InventoryMode resolves explicit cache flags before command-specific defaults.
func InventoryMode(policy config.Snapshot, mode string, refresh, explicit bool) netdisco.CacheMode {
	if refresh {
		return netdisco.CacheRefresh
	}
	if explicit {
		return netdisco.CacheMode(stringValue(policy, "netdisco.cache_mode"))
	}
	if mode == "topology" {
		return netdisco.CacheMode(stringValue(policy, "topology.cache_mode"))
	}
	return ""
}

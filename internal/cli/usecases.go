package cli

import (
	"context"
	"path/filepath"
	"strings"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/fleet"
	"github.com/gatework/net-connector/internal/bootstrap"
	"github.com/gatework/net-connector/internal/workflow"
	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/transfer"
)

// useCase is one leaf command's business operation on the shared pipeline:
// configuration → credentials → services → inventory → run → render.
// Local configuration commands (defaults, init, show, check, export) never
// reach the pipeline and have no use case.
type useCase interface {
	// prepare validates offline input, such as script files, before any
	// configuration, credential or inventory access.
	prepare(r Runtime, o options) error
	// run executes the operation with the loaded dependencies.
	run(ctx context.Context, env useCaseEnv) (workflow.Result, error)
}

// useCaseEnv carries the dependencies the pipeline loaded for a use case.
type useCaseEnv struct {
	runner   *workflow.Runner
	runtime  workflow.Runtime
	services *bootstrap.Services
	backup   workflow.BackupOptions
	rows     []inventory.Device
	options  options
	cli      Runtime
}

// sampleLimit returns the per-platform sample size selected for this command.
func (env useCaseEnv) sampleLimit() int {
	if env.options.all || env.options.mode == "topology" {
		return 0
	}
	return env.services.Limit()
}

// offline is embedded by use cases without offline input.
type offline struct{}

func (offline) prepare(Runtime, options) error { return nil }

type inventoryUseCase struct{ offline }

func (inventoryUseCase) run(_ context.Context, env useCaseEnv) (workflow.Result, error) {
	plan, err := fleet.NewPlan(env.rows, env.services.Rules(), fleet.PlanOptions{LimitPerPlatform: env.sampleLimit()})
	if err != nil {
		return workflow.Result{}, err
	}
	return workflow.Result{Success: len(plan.Tasks()) > 0, Inventory: plan.Entries()}, nil
}

type backupUseCase struct {
	offline
	preview bool
}

func (u backupUseCase) run(ctx context.Context, env useCaseEnv) (workflow.Result, error) {
	o := env.backup
	o.LimitPerPlatform = env.sampleLimit()
	return env.runner.Backup(ctx, env.runtime, env.rows, o, u.preview)
}

type tftpUseCase struct {
	offline
	preview bool
}

func (u tftpUseCase) run(ctx context.Context, env useCaseEnv) (workflow.Result, error) {
	settings, err := env.services.WorkflowTFTPSettings()
	if err != nil {
		return workflow.Result{}, err
	}
	return env.runner.TFTP(ctx, env.runtime, settings, env.rows, workflow.TFTPOptions{BackupOptions: env.backup, Plan: u.preview, All: env.options.all})
}

type deployUseCase struct {
	preview bool
	scripts workflow.DeployScripts
}

// prepare loads and validates every script before connection or sending.
func (u *deployUseCase) prepare(r Runtime, o options) error {
	scripts, err := r.loadDeployScripts(o)
	u.scripts = scripts
	return err
}

func (u *deployUseCase) run(ctx context.Context, env useCaseEnv) (workflow.Result, error) {
	o := env.options
	return env.runner.Deploy(ctx, env.runtime, env.rows, workflow.DeployOptions{
		Scripts: u.scripts, Save: o.save, Snapshot: !o.deployNoSnapshot, CommitConfirm: o.deployCommitConfirm, StopAfterFailures: o.deployStopAfter,
		Plan: u.preview, Directory: env.cli.deployDirectory(o), Policy: env.backup.Policy,
	})
}

type topologyUseCase struct {
	offline
	mode    string
	options workflow.TopologyOptions
}

func (u topologyUseCase) run(ctx context.Context, env useCaseEnv) (workflow.Result, error) {
	settings, err := env.services.WorkflowTopologySettings(u.mode)
	if err != nil {
		return workflow.Result{}, err
	}
	return env.runner.Topology(ctx, env.runtime, settings, env.rows, u.options)
}

type execUseCase struct {
	preview  bool
	commands []string
}

// prepare collects and validates every command before configuration access.
// Read-only classification is per platform and happens at plan time.
func (u *execUseCase) prepare(r Runtime, o options) error {
	text := strings.Join(o.execCommands, "\n")
	name := "--command"
	if o.execFile != "" {
		script, err := r.readScript(o.execFile)
		if err != nil {
			return err
		}
		for _, c := range script.Commands {
			u.commands = append(u.commands, c.Text)
		}
	}
	if text != "" {
		script, err := connector.ParseScript(text, name)
		if err != nil {
			return newUsageError("--command 含空命令、控制字符或非 UTF-8")
		}
		for _, c := range script.Commands {
			u.commands = append(u.commands, c.Text)
		}
	}
	if len(u.commands) == 0 {
		return newUsageError("必须通过 --command 或 --commands-file 指定只读命令")
	}
	return nil
}

func (u *execUseCase) run(ctx context.Context, env useCaseEnv) (workflow.Result, error) {
	directory := env.options.directory
	if directory == "" {
		directory = "outputs"
	}
	if !filepath.IsAbs(directory) {
		directory = filepath.Join(env.cli.CWD, directory)
	}
	return env.runner.Exec(ctx, env.runtime, env.rows, workflow.ExecOptions{Commands: u.commands, Plan: u.preview, Directory: directory, Policy: env.backup.Policy})
}

type remoteUseCase struct {
	offline
	preview bool
}

func (u remoteUseCase) run(ctx context.Context, env useCaseEnv) (workflow.Result, error) {
	o := env.options
	if o.remoteServer == "" || o.remoteUsername == "" {
		return workflow.Result{}, newUsageError("远程导出需指定 --remote-server 与 --remote-username")
	}
	options := transfer.RemoteOptions{Server: o.remoteServer, Path: o.remotePath, Username: o.remoteUsername, Protocol: o.remoteProtocol}
	if !u.preview {
		options.Password = env.services.RemoteBackupPassword()
	}
	return env.runner.RemoteBackup(ctx, env.runtime, env.rows, workflow.RemoteBackupOptions{RemoteOptions: options, LimitPerPlatform: env.sampleLimit(), Plan: u.preview, Directory: env.runtime.Directory, Policy: env.backup.Policy})
}

type factsUseCase struct {
	offline
	preview bool
}

func (u factsUseCase) run(ctx context.Context, env useCaseEnv) (workflow.Result, error) {
	directory := env.options.directory
	if directory == "" {
		directory = "facts"
	}
	if !filepath.IsAbs(directory) {
		directory = filepath.Join(env.cli.CWD, directory)
	}
	return env.runner.Facts(ctx, env.runtime, env.rows, workflow.FactsOptions{LimitPerPlatform: env.sampleLimit(), Plan: u.preview, Directory: directory, Policy: env.backup.Policy})
}

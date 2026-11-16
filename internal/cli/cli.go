// Package cli hosts the unified command tree without process-global state.
package cli

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"github.com/gatework/net-connector/config"
	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/internal/bootstrap"
	"github.com/gatework/net-connector/internal/display"
	"github.com/gatework/net-connector/internal/progress"
	"github.com/gatework/net-connector/internal/workflow"
	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/netdisco"
)

// Runtime supplies the CLI input, output and environment boundaries.
type Runtime struct {
	reporter           *progress.Reporter
	Args               []string
	Environment        map[string]string
	Input              io.Reader
	Output, Error      io.Writer
	CWD, Home, Program string
	Directories        []string
	Source             netdisco.Source
	DeviceFactory      bootstrap.DeviceFactory
}

func integerString(n int) string { return strconv.Itoa(n) }

// Run executes the CLI and returns its process exit code.
func (r Runtime) Run(ctx context.Context) int {
	if r.Input == nil {
		r.Input = os.Stdin
	}
	if r.Output == nil {
		r.Output = os.Stdout
	}
	if r.Error == nil {
		r.Error = os.Stderr
	}

	return r.runCommands(ctx)
}

const program = "netman"

func (r Runtime) executeSelected(ctx context.Context, o options, request commandRequest) int {
	if request.kind == requestDefaults {
		return r.renderDefaults(o.mode, o.json)
	}
	if r.Environment == nil {
		r.Environment = map[string]string{}
		for _, entry := range os.Environ() {
			k, v, _ := strings.Cut(entry, "=")
			r.Environment[k] = v
		}
	}
	x := &selectedRun{r: &r, o: &o, request: request, resumeSetup: func() {}}
	if !o.quiet && request.startsProgress() {
		x.reporter = progress.New(r.Error, o.verbose)
		r.reporter = x.reporter
		_ = x.reporter.Section(operationLabel(o))
		_ = x.reporter.Phase("正在加载配置")
		x.resumeSetup = x.reporter.Pause()
		defer x.resumeSetup()
		x.stopUpdates = x.reporter.RunUpdates(ctx)
		defer x.stopUpdates()
	}
	if request.kind == requestExport {
		return r.exportBatch(ctx, o.export, o.batch, o.output, o.json)
	}
	if request.kind == requestDiff {
		return r.diffBatches(ctx, o.export, o.diffFrom, o.diffTo, o.json)
	}
	if request.useCase != nil {
		if e := request.useCase.prepare(r, o); e != nil {
			return r.fail(program, e)
		}
	}
	if code, done := x.loadPolicy(ctx); done {
		return code
	}
	if code, done := x.setup(ctx); done {
		return code
	}
	if code, done := x.checkOrShow(); done {
		return code
	}
	return x.run(ctx)
}

// selectedRun is one executeSelected call: the runtime copy it mutates, the
// options and the state built step by step.
type selectedRun struct {
	r           *Runtime
	o           *options
	request     commandRequest
	reporter    *progress.Reporter
	stopUpdates func()
	resumeSetup func()
	policy      config.Snapshot
	backup      workflow.BackupOptions
	reader      *bufio.Reader
}

// loadPolicy loads the layered configuration and the backup options.
func (x *selectedRun) loadPolicy(ctx context.Context) (code int, done bool) {
	r, o, request := x.r, x.o, x.request
	policy, e := bootstrap.LoadPolicy(ctx, bootstrap.PolicyOptions{
		Mode: o.mode, CWD: r.CWD, Home: r.Home, Program: r.Program,
		Directories: r.Directories, ConfigFile: o.config, EnvFile: o.envFile,
		Environment: r.Environment, PublicOverrides: o.public,
		AllowMissing: request.kind == requestInitialize || o.interactive,
	})
	if e != nil {
		return r.fail(program, e), true
	}
	x.policy = policy
	if x.backup, e = bootstrap.BackupOptions(policy, o.mode, request.kind == requestInitialize || request.kind == requestShow); e != nil {
		return r.fail(program, e), true
	}
	return 0, false
}

// setup handles --init and interactive setup: it asks which missing files
// to create, optionally configures them interactively and writes them.
func (x *selectedRun) setup(ctx context.Context) (code int, done bool) {
	r, o, request := x.r, x.o, x.request
	if request.kind != requestInitialize && !o.interactive {
		return 0, false
	}
	name := "backup"
	if o.mode == "topology" {
		name = "topology"
	}
	var createConfig, createEnv bool
	reader := bufio.NewReader(contextInput(ctx, r.Input))
	var e error
	if request.kind == requestInitialize {
		configPath, envPath := x.policy.InitPaths()
		if createConfig, e = missingSetupFile(configPath); e != nil {
			return r.fail(program, e), true
		}
		if createEnv, e = missingSetupFile(envPath); e != nil {
			return r.fail(program, e), true
		}
		if o.interactive && (createConfig || createEnv) {
			if _, ok := r.terminal(); !ok {
				return r.fail(program, config.ErrInvalid), true
			}
		}
	} else {
		createConfig, createEnv, e = r.setupConsent(x.policy, reader)
		if errors.Is(e, errSetupDeclined) {
			return 1, true
		}
		if e != nil {
			return r.fail(program, e), true
		}
	}
	if request.kind != requestInitialize && !createConfig && !createEnv {
		return 0, false
	}
	if o.interactive && createConfig {
		if x.policy, e = r.configure(ctx, x.policy, *o, name, reader); e != nil {
			return r.fail(program, e), true
		}
	}
	created, e := config.InitializeSelected(x.policy, name, createConfig, createEnv)
	return r.renderInitialization(created, o.mode, e, o.json), true
}

// checkOrShow validates the configuration for check, prints it for show, and
// validates TFTP and topology settings before a run.
func (x *selectedRun) checkOrShow() (code int, done bool) {
	r, o, request, policy := x.r, x.o, x.request, x.policy
	if o.mode == "tftp" && (request.kind == requestCheck || request.kind == requestTFTPRun) {
		if e := bootstrap.ValidateTFTP(policy, x.backup.Policy); e != nil {
			return r.fail(program, e), true
		}
	}
	switch request.kind { //nolint:exhaustive // This helper handles only configuration requests; other operations continue below.
	case requestCheck:
		if o.mode == "topology" {
			mode, _ := policy.Value("topology.mode").(string)
			if e := bootstrap.ValidateTopology(policy, mode); e != nil {
				return r.fail(program, e), true
			}
		}
		if _, e := bootstrap.New(policy, nil); e != nil {
			return r.fail(program, e), true
		}
		return r.renderConfiguration(map[string]any{"valid": true, "scope": o.mode}, o.mode, true, o.json), true
	case requestShow:
		data := policy.Public()
		data["sources"] = policy.Sources()
		return r.renderConfiguration(data, o.mode, false, o.json), true
	default:
		// Other requests proceed to operation-specific validation.
	}
	if o.mode == "topology" {
		if e := bootstrap.ValidateTopology(policy, request.topologyMode()); e != nil {
			return r.fail(program, e), true
		}
	}
	return 0, false
}

// run resolves credentials, reads the inventory, confirms a stdin-driven
// run and executes the use case.
func (x *selectedRun) run(ctx context.Context) int {
	r, o, request, reporter := x.r, x.o, x.request, x.reporter
	env, e := x.credentials(ctx)
	if e != nil {
		return r.fail(program, e)
	}
	services, e := bootstrap.New(x.policy, func(key string) string { return env[key] })
	if e != nil {
		return r.fail(program, e)
	}
	if r.DeviceFactory != nil {
		services = services.WithDeviceFactory(r.DeviceFactory)
	}
	x.resumeSetup()
	rows, code, ok := x.inventory(ctx, services)
	if !ok {
		return code
	}
	if o.stdin && request.needsRunConfirmation() && !x.confirmRun() {
		return r.fail(program, config.ErrInvalid)
	}
	x.backup.Save = o.save
	pipeline := useCaseEnv{
		runner: &workflow.Runner{Observe: workflowObserver(reporter)}, runtime: services.WorkflowRuntime(),
		services: services, backup: x.backup, rows: rows, options: *o, cli: *r,
	}
	result, e := request.useCase.run(ctx, pipeline)
	if x.stopUpdates != nil {
		x.stopUpdates()
	}
	if reporter != nil {
		workflow.RecordFailure(ctx, &result, "progress_failed", reporter.Err())
	}
	outputErr := r.renderResult(result, *o, ctx.Err() != nil)
	workflow.RecordFailure(ctx, &result, "output_failed", outputErr)
	if ctx.Err() != nil {
		return 130
	}
	if outputErr != nil {
		return r.fail(program, outputErr)
	}
	if e != nil {
		return r.fail(program, e)
	}
	if result.Success {
		return 0
	}
	return 1
}

// credentials builds the environment the services read: prompted secrets
// replace the configured device credentials, and with --stdin a JSON line
// supplies the Netdisco and device credentials.
func (x *selectedRun) credentials(ctx context.Context) (map[string]string, error) {
	resume := x.reporter.Pause()
	passwordErr := x.r.passwords(ctx, x.o)
	resume()
	if passwordErr != nil {
		return nil, passwordErr
	}
	env := x.policy.Environment()
	for key, value := range x.o.secrets {
		applySecret(env, key, value)
	}
	x.reader = bufio.NewReader(contextInput(ctx, x.r.Input))
	if !x.o.stdin {
		return env, nil
	}
	if x.reporter != nil {
		_ = x.reporter.Phase("等待标准输入凭据：请输入一行 JSON")
	}
	line, e := readLine(x.reader, 64<<10)
	if e != nil {
		return nil, e
	}
	var creds map[string]string
	if json.Unmarshal([]byte(line), &creds) != nil {
		return nil, config.ErrInvalid
	}
	for key, target := range map[string]string{ //nolint:gosec // maps setting names to environment variable names, not secrets
		"netdisco_username": "ND_USERNAME", "netdisco_password": "ND_PASSWORD", "device_username": "NC_DEVICE_USERNAME", "device_password": "NC_DEVICE_PASSWORD"} {
		if strings.TrimSpace(creds[key]) == "" {
			return nil, config.ErrInvalid
		}
		if target == "NC_DEVICE_USERNAME" || target == "NC_DEVICE_PASSWORD" {
			dropVariants(env, strings.TrimPrefix(target, "NC_DEVICE_"))
		}
		env[target] = creds[key]
	}
	delete(env, "ND_API_KEY")
	return env, nil
}

// applySecret sets one prompted secret; a device credential replaces every
// per-platform variant, and Netdisco user credentials replace an API key.
func applySecret(env map[string]string, key, value string) {
	suffix := map[string]string{"NC_DEVICE_USERNAME": "USERNAME", "NC_DEVICE_PASSWORD": "PASSWORD", "NC_ENABLE_PASSWORD": "ENABLE_PASSWORD"}[key]
	if suffix != "" {
		for name := range env {
			if strings.HasPrefix(name, "NC_") && strings.HasSuffix(name, "_"+suffix) && (suffix != "PASSWORD" || !strings.HasSuffix(name, "_ENABLE_PASSWORD")) {
				delete(env, name)
			}
		}
	}
	if key == "ND_USERNAME" || key == "ND_PASSWORD" {
		delete(env, "ND_API_KEY")
	}
	env[key] = value
}

// dropVariants removes every NC_*_suffix device credential except enable
// passwords.
func dropVariants(env map[string]string, suffix string) {
	for name := range env {
		if strings.HasPrefix(name, "NC_") && strings.HasSuffix(name, "_"+suffix) && !strings.HasSuffix(name, "_ENABLE_PASSWORD") {
			delete(env, name)
		}
	}
}

// inventory reads the device inventory; ok is false when the command must
// exit with code.
func (x *selectedRun) inventory(ctx context.Context, services *bootstrap.Services) (rows []inventory.Device, code int, ok bool) {
	r, o, reporter := x.r, x.o, x.reporter
	if reporter != nil {
		_ = reporter.Phase("正在读取设备清单")
	}
	var e error
	if r.Source != nil {
		rows, e = r.Source.Devices(ctx)
	} else {
		var result netdisco.CacheResult
		result, e = services.Inventory(ctx, bootstrap.InventoryMode(x.policy, o.mode, o.refresh, o.flags.Changed("cache-only") || o.flags.Changed("cache-mode")))
		rows = result.Rows
		if result.RefreshErrorCode != "" {
			_ = reporter.Warning("设备清单刷新失败，已使用校验通过的缓存") // progress output failures are reported by the reporter itself
		}
		if result.WriteErrorType != "" {
			_ = reporter.Warning("清单缓存写入失败，继续使用本次获取的清单")
		}
	}
	if e != nil {
		if ctx.Err() != nil {
			return nil, 130, false
		}
		return nil, r.fail(program, e), false
	}
	if reporter != nil {
		_ = reporter.Phase(fmt.Sprintf("设备清单读取完成：%d 台；正在生成计划", len(rows)))
	}
	return rows, 0, true
}

// confirmRun requires the stdin line RUN before a run that changes devices.
func (x *selectedRun) confirmRun() bool {
	if x.reporter != nil {
		_ = x.reporter.Phase("等待执行确认：请输入 RUN")
	}
	resumeConfirm := x.reporter.Pause()
	_ = x.reporter.Notice("等待执行确认：请输入 RUN")
	line, e := readLine(x.reader, 64)
	resumeConfirm()
	return e == nil && strings.TrimSpace(line) == "RUN"
}
func readLine(reader *bufio.Reader, limit int) (string, error) {
	var b strings.Builder
	for {
		part, prefix, e := reader.ReadLine()
		if e != nil {
			return "", e
		}
		if b.Len()+len(part) > limit {
			return "", config.ErrInvalid
		}
		b.Write(part)
		if !prefix {
			return b.String(), nil
		}
	}
}
func (r Runtime) print(v any) int {
	enc := json.NewEncoder(r.Output)
	enc.SetIndent("", "  ")
	if e := enc.Encode(v); e != nil {
		return r.fail("netman", e)
	}
	return 0
}
func (r Runtime) fail(program string, e error) int {
	if errors.Is(e, context.Canceled) {
		return 130
	}
	message := "操作失败（输入无效、数据源不可用或 I/O 错误）"
	if usage, ok := errors.AsType[*usageError](e); ok {
		message = usage.message
	}
	if classified, ok := errors.AsType[*connector.Error](e); ok {
		message = display.Error(classified.Code)
	}
	var inventoryError *netdisco.InventoryError
	if errors.As(e, &inventoryError) && inventoryError.Code == "cache_namespace_required" {
		message = display.Error(inventoryError.Code)
	}
	if errors.Is(e, netdisco.ErrCacheRefreshRequired) {
		message = "离线清单缓存不可用，请先使用 prefer 或 refresh 模式刷新对应来源（cache_unavailable）"
	}
	if errors.Is(e, config.ErrInvalid) {
		message = "配置或参数无效，请使用 --help 查看用法并检查配置文件"
	}
	if field, ok := errors.AsType[*config.FieldError](e); ok {
		switch field.Problem {
		case "required":
			message = "配置 " + display.Text(field.Field) + " 未设置；请通过配置文件、环境变量或对应选项设置"
		default:
			message = "配置 " + display.Text(field.Field) + " 无效；请通过配置文件、环境变量或对应选项设置"
		}
	}
	if errors.Is(e, workflow.ErrTFTPArchivePreflight) {
		message = "TFTP 归档预检失败：请检查归档服务器 SSH 认证、远端 tftp-archive 是否已安装且协议兼容，以及归档目录权限；本次尚未开始设备上传"
	}
	if r.reporter != nil {
		_ = r.reporter.Warning(program + "：" + message)
	} else {
		fmt.Fprintln(r.Error, program+"："+message)
	}
	return 2
}

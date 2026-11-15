package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"

	"github.com/spf13/cobra"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/internal/batchreport"
	"github.com/gatework/net-connector/internal/buildinfo"
	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/netdisco"
)

type exitError int

func (e exitError) Error() string { return "命令未完成" }

type usageError struct{ message string }

func (e *usageError) Error() string      { return e.message }
func newUsageError(message string) error { return &usageError{message} }

func (r Runtime) runCommands(ctx context.Context) int {
	var outputErr error
	root := r.commandTree(ctx, &outputErr)
	root.SetArgs(append([]string{}, r.Args...))
	root.SetIn(r.Input)
	root.SetOut(&commandOutput{writer: r.Output, first: &outputErr})
	root.SetErr(r.Error)
	err := root.ExecuteContext(ctx)
	if outputErr != nil {
		err = outputErr
	}
	if errors.Is(err, context.Canceled) || ctx.Err() != nil {
		return 130
	}
	if err == nil {
		return 0
	}
	if exit, ok := errors.AsType[exitError](err); ok {
		return int(exit)
	}
	message := "命令或参数无效，请使用 netman help 查看用法"
	if bad, ok := errors.AsType[*usageError](err); ok {
		message = bad.message
	}
	fmt.Fprintln(r.Error, "netman："+message)
	return 2
}

func (r Runtime) commandTree(ctx context.Context, outputErr *error) *cobra.Command {
	var configFile, envFile string
	root := &cobra.Command{Use: "netman", Short: "网络设备配置备份、清单与拓扑管理", Long: "统一管理配置采集、原生上传、设备清单和拓扑；帮助、版本和补全不读取配置或凭据。", SilenceErrors: true, SilenceUsage: true, Version: buildinfo.Identity}
	root.CompletionOptions.DisableDefaultCmd = true
	root.PersistentFlags().StringVar(&configFile, "config", "", "最后加载的配置`文件`；相对路径从启动目录解析")
	root.PersistentFlags().StringVar(&envFile, "env-file", "", "最后加载的环境`文件`；不修改进程环境")
	root.Flags().BoolP("version", "v", false, "显示版本和源码修订号")
	root.SetVersionTemplate("netman {{.Version}}\n")
	root.SetFlagErrorFunc(func(c *cobra.Command, _ error) error {
		return newUsageError("选项无效或缺少参数，请使用 " + c.CommandPath() + " --help 查看用法")
	})
	root.SetHelpFunc(func(c *cobra.Command, _ []string) {
		if err := renderChineseHelp(c, c.OutOrStdout()); err != nil && *outputErr == nil {
			*outputErr = err
		}
	})
	root.SetUsageFunc(func(c *cobra.Command) error { return renderChineseHelp(c, c.OutOrStdout()) })
	root.RunE = func(c *cobra.Command, _ []string) error { return renderChineseHelp(c, c.OutOrStdout()) }
	root.Args = noArguments
	help := &cobra.Command{Use: "help [命令路径]", Short: "显示指定命令的中文帮助", Long: "按命令层级查询帮助，不读取配置文件或凭据。", Example: "  netman help backup run", RunE: func(c *cobra.Command, args []string) error {
		target, remaining, err := root.Find(args)
		if err != nil || len(remaining) > 0 {
			return newUsageError("未找到指定命令，请使用 netman --help 查看子命令")
		}
		return renderChineseHelp(target, c.OutOrStdout())
	}}
	root.SetHelpCommand(help)
	leaf := r.leafFactory(&configFile, &envFile)
	addBackupCommands(root, leaf)
	addInventoryCommands(root, leaf)
	addTopologyCommands(root, leaf)
	addDeployCommands(root, leaf)
	addExecCommands(root, leaf)
	addFactsCommands(root, leaf)
	addConfigCommands(root, leaf)
	addPlatformCommands(root)
	addCompletionCommands(root)
	root.AddCommand(&cobra.Command{Use: "version", Short: "显示版本与源码修订号", Long: "显示构建身份，不读取配置或凭据。", Example: "  netman version", Args: noArguments, RunE: func(c *cobra.Command, _ []string) error {
		_, err := fmt.Fprintln(c.OutOrStdout(), "netman", buildinfo.Identity)
		return err
	}})
	customizeTree(root)
	return root
}

// leafFactory returns the constructor of runnable commands. Each leaf owns
// its options, prepares them from its flags and the global --config and
// --env-file before running, and executes the selected request.
func (r Runtime) leafFactory(configFile, envFile *string) func(parent *cobra.Command, name, short, mode, action string, bind func(*cobra.Command, *options)) *cobra.Command {
	return func(parent *cobra.Command, name, short, mode, action string, bind func(*cobra.Command, *options)) *cobra.Command {
		o := options{mode: mode, action: action, policy: "selected", layout: "batch", public: map[string]string{}, secrets: map[string]string{}}
		var request commandRequest
		c := &cobra.Command{Use: name, Short: short, Long: short, Args: noArguments, Example: "  netman " + parent.Name() + " " + strings.Fields(name)[0] + " --help"}
		bind(c, &o)
		c.PreRunE = func(c *cobra.Command, args []string) error {
			o.config = *configFile
			o.envFile = *envFile
			o.flags = c.Flags()
			if action == "export" || action == "diff" {
				o.export = args[0]
			}
			if err := prepareCommandOptions(c, &o); err != nil {
				return err
			}
			var err error
			request, err = newCommandRequest(o)
			return err
		}
		c.RunE = func(c *cobra.Command, _ []string) error {
			if code := r.executeSelected(c.Context(), o, request); code != 0 {
				return exitError(code)
			}
			return nil
		}
		parent.AddCommand(c)
		return c
	}
}

// customizeTree localizes the help flag and registers value completions on
// c and every descendant.
func customizeTree(c *cobra.Command) {
	c.InitDefaultHelpFlag()
	if f := c.Flags().Lookup("help"); f != nil {
		f.Usage = "显示当前命令的中文帮助"
	}
	for name, values := range flagCompletions() {
		if c.Flags().Lookup(name) != nil {
			_ = c.RegisterFlagCompletionFunc(name, completeFrom(values))
		}
	}
	for _, child := range c.Commands() {
		customizeTree(child)
	}
}

// completeFrom completes a flag value from a fixed list.
func completeFrom(values []string) cobra.CompletionFunc {
	return func(_ *cobra.Command, _ []string, prefix string) ([]string, cobra.ShellCompDirective) {
		var matches []string
		for _, value := range values {
			if strings.HasPrefix(value, prefix) {
				matches = append(matches, value)
			}
		}
		return matches, cobra.ShellCompDirectiveNoFileComp
	}
}
func noArguments(_ *cobra.Command, args []string) error {
	if len(args) > 0 {
		return newUsageError("存在未知子命令或多余的位置参数")
	}
	return nil
}

type commandBuilder func(*cobra.Command, string, string, string, string, func(*cobra.Command, *options)) *cobra.Command

func commandGroup(name, description string) *cobra.Command {
	return &cobra.Command{Use: name, Short: description, Long: description, Args: noArguments, RunE: func(c *cobra.Command, _ []string) error { return renderChineseHelp(c, c.OutOrStdout()) }}
}

type commandOutput struct {
	writer io.Writer
	first  *error
}

func (w *commandOutput) Write(p []byte) (int, error) {
	n, err := w.writer.Write(p)
	if err == nil && n != len(p) {
		err = io.ErrShortWrite
	}
	if err != nil && *w.first == nil {
		*w.first = err
	}
	return n, err
}

// flagCompletions maps enumerated flags to their accepted values. Values come
// from the packages that validate them so completion cannot drift.
func flagCompletions() map[string][]string {
	return map[string][]string{
		"layout":          batchreport.Layouts(),
		"method":          {"cli", "tftp", "remote"},
		"remote-protocol": {"scp", "ftp"},
		"success-policy":  batchreport.SuccessPolicies(),
		"protocol":        {string(connector.ProtocolSSH), string(connector.ProtocolTelnet)},
		"host-key-policy": {string(connector.HostKeyStrict), string(connector.HostKeyAcceptNew), string(connector.HostKeyReplace)},
		"cache-mode":      netdisco.CacheModes(),
		"source":          {"http", "postgres"},
		"for":             {"backup", "tftp", "topology"},
		"name-match":      inventory.MatchModes(),
		"model-match":     inventory.MatchModes(),
	}
}

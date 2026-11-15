package cli

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"unicode"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/internal/display"
	"github.com/gatework/net-connector/internal/workflow"
	"github.com/gatework/net-connector/vendors"
)

// maxScriptBytes bounds one script file before parsing.
const maxScriptBytes = 1 << 20

// loadDeployScripts reads and validates every script before configuration,
// credentials, inventory or any device connection is touched.
func (r Runtime) loadDeployScripts(o options) (workflow.DeployScripts, error) {
	scripts := workflow.DeployScripts{ByPlatform: map[string]connector.Script{}}
	if o.deployScript == "" && len(o.deployScriptFor) == 0 {
		return scripts, newUsageError("必须通过 --script 或 --script-for 指定命令脚本")
	}
	if o.deployStopAfter < 0 {
		return scripts, newUsageError("--stop-after-failures 不能为负数")
	}
	if o.deployCommitConfirm < 0 || o.deployCommitConfirm > 60 {
		return scripts, newUsageError("--commit-confirm 需为 1 至 60 分钟")
	}
	known := map[string]bool{}
	for _, name := range vendors.NewBuiltinRegistry().Names() {
		known[name] = true
	}
	if o.deployScript != "" {
		script, err := r.readScript(o.deployScript)
		if err != nil {
			return scripts, err
		}
		scripts.Default = &script
	}
	for _, entry := range o.deployScriptFor {
		platform, path, ok := strings.Cut(entry, "=")
		if !ok || platform == "" || path == "" {
			return scripts, newUsageError("--script-for 格式应为 平台=文件")
		}
		if !known[platform] {
			return scripts, newUsageError("未知平台 " + display.Text(platform) + "；可用平台：" + strings.Join(vendors.NewBuiltinRegistry().Names(), "、"))
		}
		if _, exists := scripts.ByPlatform[platform]; exists {
			return scripts, newUsageError("平台 " + platform + " 重复指定了脚本")
		}
		script, err := r.readScript(path)
		if err != nil {
			return scripts, err
		}
		scripts.ByPlatform[platform] = script
	}
	return scripts, nil
}

func (r Runtime) readScript(path string) (connector.Script, error) {
	if !filepath.IsAbs(path) {
		path = filepath.Join(r.CWD, path)
	}
	name := filepath.Base(path)
	file, err := os.Open(path)
	if err != nil {
		return connector.Script{}, newUsageError("无法读取脚本 " + display.Text(name))
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxScriptBytes+1))
	if err != nil {
		return connector.Script{}, newUsageError("无法读取脚本 " + display.Text(name))
	}
	if len(data) > maxScriptBytes {
		return connector.Script{}, newUsageError("脚本 " + display.Text(name) + " 超过 1 MiB")
	}
	script, err := connector.ParseScript(string(data), name)
	if err != nil {
		if invalid, ok := errors.AsType[*connector.Error](err); ok && invalid.Line > 0 {
			return connector.Script{}, newUsageError(fmt.Sprintf("脚本 %s 第 %d 行无效（含 NUL 或非 UTF-8 字符）", display.Text(name), invalid.Line))
		}
		return connector.Script{}, newUsageError("脚本 " + display.Text(name) + " 无效")
	}
	if len(script.Commands) == 0 {
		return connector.Script{}, newUsageError("脚本 " + display.Text(name) + " 没有命令")
	}
	// A control byte such as Ctrl-A or ESC would be interpreted by the device
	// line editor rather than sent as command text; reject it before connecting.
	for _, command := range script.Commands {
		if strings.ContainsFunc(command.Text, func(c rune) bool { return c != '\t' && unicode.IsControl(c) }) {
			return connector.Script{}, newUsageError(fmt.Sprintf("脚本 %s 第 %d 行含控制字符", display.Text(name), command.Line))
		}
	}
	return script, nil
}

// deployDirectory resolves the output directory against the launch directory.
func (r Runtime) deployDirectory(o options) string {
	directory := o.directory
	if directory == "" {
		directory = "deploys"
	}
	if !filepath.IsAbs(directory) {
		directory = filepath.Join(r.CWD, directory)
	}
	return directory
}

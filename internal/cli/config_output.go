package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"

	"go.yaml.in/yaml/v3"

	"github.com/gatework/net-connector/config"
	"github.com/gatework/net-connector/internal/display"
)

func (r Runtime) renderDefaults(scope string, jsonOutput bool) int {
	data := config.Defaults(scope)
	var body []byte
	var err error
	if jsonOutput {
		body, err = json.MarshalIndent(data, "", "  ")
		body = append(body, '\n')
	} else {
		body, err = yaml.Marshal(data)
	}
	if err != nil {
		return r.fail("netman", err)
	}
	n, err := r.Output.Write(body)
	if err == nil && n != len(body) {
		err = io.ErrShortWrite
	}
	if err != nil {
		return r.fail("netman", err)
	}
	return 0
}

func (r Runtime) renderInitialization(created []string, scope string, cause error, jsonOutput bool) int {
	if jsonOutput {
		if code := r.print(map[string]any{"created": created, "scope": scope, "success": cause == nil}); code != 0 {
			return code
		}
	} else {
		var text strings.Builder
		for _, path := range created {
			fmt.Fprintln(&text, "已初始化：", display.Text(path))
		}
		if cause == nil {
			fmt.Fprintln(&text, "请检查配置后重新运行；本次未访问清单服务或设备。")
		}
		n, err := io.WriteString(r.Error, text.String())
		if err == nil && n != text.Len() {
			err = io.ErrShortWrite
		}
		if err != nil {
			return r.fail("netman", err)
		}
	}
	if cause != nil {
		return r.fail("netman", cause)
	}
	return 0
}

func (r Runtime) renderConfiguration(data map[string]any, scope string, check, jsonOutput bool) int {
	if jsonOutput {
		return r.print(data)
	}
	label := map[string]string{"backup": "配置备份", "tftp": "TFTP 备份", "topology": "拓扑"}[scope]
	text := "配置检查通过：" + label + "（仅检查本地配置）\n"
	if !check {
		body, err := yaml.Marshal(data)
		if err != nil {
			return r.fail("netman", err)
		}
		text = "有效配置：" + label + "\n" + string(body)
	}
	n, err := fmt.Fprint(r.Output, text)
	if err == nil && n != len(text) {
		err = io.ErrShortWrite
	}
	if err != nil {
		return r.fail("netman", err)
	}
	return 0
}

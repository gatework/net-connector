package cli

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"maps"
	"net/url"
	"os"
	"strings"

	"golang.org/x/term"

	"github.com/gatework/net-connector/config"
	"github.com/gatework/net-connector/internal/bootstrap"
	"github.com/gatework/net-connector/transfer"
)

var errSetupDeclined = errors.New("未创建必需的配置文件")

func missingSetupFile(path string) (bool, error) {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return true, nil
	}
	if err != nil || !info.Mode().IsRegular() {
		return false, config.ErrInvalid
	}
	return false, nil
}

func (r Runtime) setupConsent(snapshot config.Snapshot, reader *bufio.Reader) (bool, bool, error) {
	configPath, envPath := snapshot.InitPaths()
	configMissing, err := missingSetupFile(configPath)
	if err != nil {
		return false, false, err
	}
	envMissing, err := missingSetupFile(envPath)
	if err != nil {
		return false, false, err
	}
	if !configMissing && !envMissing {
		return false, false, nil
	}
	if _, ok := r.terminal(); !ok {
		return false, false, config.ErrInvalid
	}
	approve := func(path string) (bool, error) {
		for {
			if _, err := fmt.Fprintf(r.Error, "未找到文件：%s；是否创建？[y/N]：", path); err != nil {
				return false, err
			}
			line, err := readLine(reader, 64)
			if err != nil {
				return false, err
			}
			switch strings.ToLower(strings.TrimSpace(line)) {
			case "y", "yes":
				return true, nil
			case "", "n", "no":
				return false, nil
			}
			if _, err := fmt.Fprintln(r.Error, "请输入 y 或 n。"); err != nil {
				return false, err
			}
		}
	}
	createConfig, createEnv := false, false
	if configMissing {
		createConfig, err = approve(configPath)
		if err != nil {
			return false, false, err
		}
		if !createConfig {
			return false, false, errSetupDeclined
		}
	}
	if envMissing {
		createEnv, err = approve(envPath)
	}
	return createConfig, createEnv, err
}

func (r Runtime) terminal() (*os.File, bool) {
	input, ok := r.Input.(*os.File)
	if !ok || !term.IsTerminal(int(input.Fd())) {
		return nil, false
	}
	output, ok := r.Error.(*os.File)
	return input, ok && term.IsTerminal(int(output.Fd()))
}
func (r Runtime) passwords(ctx context.Context, o *options) error {
	for _, p := range []struct{ flag, key, label string }{{"ask-password", "NC_DEVICE_PASSWORD", "设备密码"}, {"ask-netdisco-password", "ND_PASSWORD", "Netdisco 密码"}} {
		ask, _ := o.flags.GetBool(p.flag)
		if !ask {
			continue
		}
		input, ok := r.terminal()
		if !ok {
			return config.ErrInvalid
		}
		fmt.Fprint(r.Error, p.label+": ")
		password, e := readTerminalSecret(ctx, input)
		fmt.Fprintln(r.Error)
		if e != nil {
			return e
		}
		if len(password) == 0 || strings.ContainsAny(password, "\r\n\x00") {
			return config.ErrInvalid
		}
		o.secrets[p.key] = password
	}
	return nil
}

// configure interviews the operator for the settings a new configuration
// still lacks and reloads the configuration with them.
func (r Runtime) configure(ctx context.Context, snapshot config.Snapshot, o options, name string, reader *bufio.Reader) (config.Snapshot, error) {
	if _, ok := r.terminal(); !ok {
		return snapshot, config.ErrInvalid
	}
	path, _ := snapshot.InitPaths()
	if _, e := os.Lstat(path); e == nil {
		return snapshot, nil
	}
	in := &interview{out: r.Error, reader: reader, values: map[string]string{}}
	start, e := in.answer("是否开始交互式配置？y/N", "n")
	if e != nil || !strings.EqualFold(start, "y") {
		return snapshot, e
	}
	maps.Copy(in.values, o.public)
	if e = in.inventory(snapshot); e != nil {
		return snapshot, e
	}
	if o.mode == "tftp" {
		if e = in.tftp(snapshot); e != nil {
			return snapshot, e
		}
	}
	// Keep the originally selected config/env paths and environment precedence.
	overrides, e := config.FromEnvironment(in.values)
	if e != nil {
		return snapshot, e
	}
	result, e := config.Load(ctx, config.Options{Name: name, CWD: r.CWD, Home: r.Home, Program: r.Program, Directories: r.Directories, ConfigFile: o.config, EnvFile: o.envFile, Defaults: snapshot.Public(), Overrides: overrides, Environment: r.Environment, AllowMissing: true})
	if e == nil {
		_, e = bootstrap.New(result, nil)
	}
	return result, e
}

// interview asks configuration questions on the terminal and collects the
// answers as environment overrides.
type interview struct {
	out    io.Writer
	reader *bufio.Reader
	values map[string]string
}

// answer asks one question; an empty answer takes defaultValue.
func (in *interview) answer(label, defaultValue string) (string, error) {
	if _, e := fmt.Fprintf(in.out, "%s [%s]: ", label, defaultValue); e != nil {
		return "", e
	}
	line, e := readLine(in.reader, 64<<10)
	if e != nil {
		return "", e
	}
	if line = strings.TrimSpace(line); line == "" {
		line = defaultValue
	}
	return line, nil
}

// ask repeats a question until valid accepts the answer and records it as key.
func (in *interview) ask(key, label, defaultValue string, valid func(string) bool) error {
	for {
		value, err := in.answer(label, defaultValue)
		if err != nil {
			return err
		}
		if valid(value) {
			in.values[key] = value
			return nil
		}
		if _, err = fmt.Fprintln(in.out, "值无效，请重新输入。"); err != nil {
			return err
		}
	}
}

// inventory asks for the inventory source and its URL or query when the
// configuration does not set them.
func (in *interview) inventory(snapshot config.Snapshot) error {
	source, _ := snapshot.Value("netdisco.source").(string)
	if source == "" {
		source = "http"
	}
	urlValue, _ := snapshot.Value("netdisco.url").(string)
	query, _ := snapshot.Value("netdisco.query").(string)
	fields, _ := snapshot.Sources()["fields"].(map[string]string)
	if source == "http" && urlValue == "" && query == "" && fields["/netdisco/source"] == "default" {
		if e := in.ask("ND_SOURCE", "清单来源 http/postgres", source, func(v string) bool { return v == "http" || v == "postgres" }); e != nil {
			return e
		}
		source = in.values["ND_SOURCE"]
	}
	if source == "http" && urlValue == "" {
		if e := in.ask("ND_URL", "清单服务地址", "", func(v string) bool {
			u, err := url.Parse(v)
			return err == nil && u.Host != "" && u.User == nil && (u.Scheme == "https" || u.Scheme == "http")
		}); e != nil {
			return e
		}
	}
	if source == "postgres" && query == "" {
		return in.ask("ND_QUERY", "PostgreSQL 只读清单查询", "", func(v string) bool { return strings.TrimSpace(v) != "" })
	}
	return nil
}

// tftp asks for the TFTP server and its archive root when unset.
func (in *interview) tftp(snapshot config.Snapshot) error {
	server, _ := snapshot.Value("tftp.server").(string)
	servers, _ := snapshot.Value("tftp.servers").(map[string]any)
	if server == "" && len(servers) == 0 {
		if e := in.ask("NC_TFTP_HOST", "TFTP 服务器地址", "", func(v string) bool { return transfer.ValidateServer(v) == nil }); e != nil {
			return e
		}
		server = in.values["NC_TFTP_HOST"]
	}
	root, _ := snapshot.Value("tftp.verification_root").(string)
	roots, _ := snapshot.Value("tftp.verification_roots").(map[string]any)
	if server != "" && root == "" && roots[server] == nil {
		return in.ask("NC_TFTP_ROOT", "TFTP 归档根目录（本地路径或 ssh://用户@服务器/目录）", "", func(v string) bool { _, err := transfer.VerificationRoot(v); return err == nil })
	}
	return nil
}

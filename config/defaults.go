package config

import (
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/gatework/net-connector/internal/batchreport"

	"go.yaml.in/yaml/v3"

	"github.com/gatework/net-connector/archive"
)

// Defaults returns a fresh configuration with the requested operation defaults.
func Defaults(mode string) map[string]any {
	m := map[string]any{
		"netdisco": map[string]any{
			"source": "http", "cache_enabled": true, "cache_mode": "prefer", "cache_ttl": 259200,
			"cache_directory": "./.cache/net-connector/inventory", "inventory_timeout": 300,
			"page_size": 500, "max_pages": 10000, "max_devices": 100000,
			"max_response_bytes": 16 << 20, "max_inventory_bytes": 128 << 20,
			"db_port": 5432, "db_connect_timeout": 10, "allow_insecure_http": false,
		},
		"inventory": map[string]any{
			"include_hosts": []any{}, "exclude_hosts": []any{}, "include_names": []any{},
			"exclude_names": []any{}, "include_platforms": []any{}, "exclude_platforms": []any{},
			"include_models": []any{}, "exclude_models": []any{},
			"name_match": "contains", "model_match": "contains", "source": "netdisco",
		},
		"ssh":    map[string]any{"protocol": "ssh", "host_key_policy": "accept_new", "log_level": "info", "connect_retries": 1},
		"backup": map[string]any{"directory": "./backups", "parallel": 4, "limit_per_platform": 0, "layout": "batch"},
	}
	// One flat document serves every command; only the command's success policy
	// default differs. Topology inherits backup.parallel unless explicitly set.
	m["topology"] = map[string]any{"mode": "plan", "cache_mode": "prefer", "directory": "./topologys", "description_format": "To_%{neighbor}_%{port}", "abbreviate_ports": true, "lowercase_ports": false, "neighbor_name_prefixes": []any{}}
	timeouts := archive.DefaultTimeouts()
	m["tftp"] = map[string]any{"ssh_worker_path": archive.DefaultWorkerPath, "upload_timeout": int(timeouts.Upload / time.Second), "archive_prepare_timeout": int(timeouts.Prepare / time.Second), "archive_verify_timeout": int(timeouts.Verify / time.Second), "archive_cleanup_timeout": int(timeouts.Cleanup / time.Second)}
	policy := batchreport.PolicySelected
	if mode == "tftp" {
		policy = batchreport.PolicyVerified
	}
	setPath(m, "backup.success_policy", string(policy))
	return m
}

// EnvironmentTemplate is the credential file template used for initialization.
const EnvironmentTemplate = `# CLI > 进程环境 > YAML > .env > 默认值。
# 凭据不会写入 YAML，仅填写实际使用的变量。
# ND_URL=
# ND_USERNAME=
# ND_PASSWORD=
# ND_API_KEY=
# API key 启用清单缓存时，用同一非敏感账户标识 ND_USERNAME 或 ND_CACHE_NAMESPACE 隔离不同主体。
# ND_CACHE_NAMESPACE=
# NC_DEVICE_USERNAME=
# NC_DEVICE_PASSWORD=
# NC_ENABLE_PASSWORD=
# ND_DB_HOST=
# ND_DB_NAME=
# ND_DB_USER=
# ND_DB_PASS=
# NC_TFTP_SSH_PASSWORD=
# 单引号保留 # 和 $ 的字面含义。
`

// InitializeSelected publishes only the files whose creation was approved.
func InitializeSelected(s Snapshot, name string, createConfig, createEnv bool) ([]string, error) {
	doc := s.initializationValues()
	path, env := s.InitPaths()
	data, e := yaml.Marshal(doc)
	if e != nil {
		return nil, ErrInvalid
	}
	created := []string{}
	for _, item := range []struct {
		path   string
		data   []byte
		create bool
	}{{path, data, createConfig}, {env, []byte(EnvironmentTemplate), createEnv}} {
		if !item.create {
			continue
		}
		if info, e := os.Lstat(item.path); e == nil {
			if !info.Mode().IsRegular() {
				return created, ErrInvalid
			}
			continue
		} else if !os.IsNotExist(e) {
			return created, ErrInvalid
		}
		if e = os.MkdirAll(filepath.Dir(item.path), 0700); e != nil {
			return created, e
		}
		f, e := os.OpenFile(item.path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if e != nil {
			return created, e
		}
		n, e := f.Write(item.data)
		if e == nil && n != len(item.data) {
			e = io.ErrShortWrite
		}
		if e == nil {
			e = f.Sync()
		}
		ce := f.Close()
		if e == nil {
			e = ce
		}
		if e != nil {
			_ = os.Remove(item.path)
			return created, e
		}
		created = append(created, item.path)
	}
	return created, nil
}

// FromEnvironment decodes supported public settings from explicitly supplied variables.
func FromEnvironment(values map[string]string) (map[string]any, error) {
	return environmentValues(values, nil, nil)
}

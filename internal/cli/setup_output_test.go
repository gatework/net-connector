package cli

import (
	"bufio"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/creack/pty"

	"github.com/gatework/net-connector/config"
	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/netdisco"
)

func TestSetupAsksOnlyMissingEnvironmentFacts(t *testing.T) {
	for _, tc := range []struct{ name, answers, url string }{
		{"new", "y\nhttp\nhttps://inventory.example.test\n", ""},
		{"existing", "y\n", "https://inventory.example.test"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r, _, _ := fixtureRuntime(t)
			master, slave, err := pty.Open()
			if err != nil {
				t.Fatal(err)
			}
			defer master.Close()
			defer slave.Close()
			r.Input, r.Error = slave, slave
			if tc.url != "" {
				r.Environment["ND_URL"] = tc.url
			}
			p, err := config.Load(context.Background(), config.Options{Name: "backup", CWD: r.CWD, Home: r.Home, Directories: []string{}, Environment: r.Environment, Defaults: config.Defaults("backup"), AllowMissing: true})
			if err != nil {
				t.Fatal(err)
			}
			p, err = r.configure(t.Context(), p, options{mode: "backup"}, "backup", bufio.NewReader(strings.NewReader(tc.answers)))
			if err != nil || p.Value("netdisco.url") != "https://inventory.example.test" {
				t.Fatalf("setup error=%v", err)
			}
			if _, err = config.InitializeSelected(p, "backup", true, false); err != nil {
				t.Fatal(err)
			}
			path, _ := p.InitPaths()
			body, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			for _, redundant := range []string{"include_hosts:", "parallel:", "cache_ttl:", "example.invalid"} {
				if strings.Contains(string(body), redundant) {
					t.Fatalf("redundant setup field in %s", body)
				}
			}
		})
	}
}

func TestInitializationJSONReportsCreatedFiles(t *testing.T) {
	r, out, diag := fixtureRuntime(t)
	r.Args = []string{"config", "init", "--non-interactive", "--json"}
	if code := r.Run(t.Context()); code != 0 {
		t.Fatalf("code=%d diagnostics=%s", code, diag)
	}
	var result struct {
		Success bool     `json:"success"`
		Created []string `json:"created"`
	}
	if err := json.Unmarshal(out.Bytes(), &result); err != nil || !result.Success || len(result.Created) != 2 {
		t.Fatalf("result=%s error=%v", out, err)
	}
	for _, path := range result.Created {
		if _, err := os.Stat(path); err != nil {
			t.Fatal(err)
		}
	}
	if diag.Len() != 0 {
		t.Fatal(diag.String())
	}
}

func TestExportFileHasHumanAndExplicitJSONOutput(t *testing.T) {
	for _, jsonOutput := range []bool{false, true} {
		r, out, diag := fixtureRuntime(t)
		batch := exportBatchFixture(t)
		destination := filepath.Join(t.TempDir(), "saved.txt")
		r.Args = []string{"backup", "export", "192.0.2.1", "--batch", batch, "--output", destination}
		if jsonOutput {
			r.Args = append(r.Args, "--json")
		}
		if code := r.Run(t.Context()); code != 0 {
			t.Fatalf("code=%d diagnostics=%s", code, diag)
		}
		if jsonOutput {
			if !json.Valid(out.Bytes()) {
				t.Fatal(out.String())
			}
		} else if !strings.Contains(out.String(), "已导出：") || json.Valid(out.Bytes()) {
			t.Fatal(out.String())
		}
		body, err := os.ReadFile(destination)
		if err != nil || string(body) != "中文配置\n" {
			t.Fatalf("body=%q error=%v", body, err)
		}
	}
}

func TestExplicitFalseOverridesConfiguration(t *testing.T) {
	var outputErr error
	root := (Runtime{}).commandTree(t.Context(), &outputErr)
	c, _, err := root.Find([]string{"topology", "plan"})
	if err != nil {
		t.Fatal(err)
	}
	if err = c.ParseFlags([]string{"--lowercase-ports=false", "--full-port-names=false"}); err != nil {
		t.Fatal(err)
	}
	o := options{mode: "topology", action: "plan", layout: "batch", policy: "selected", public: map[string]string{}, secrets: map[string]string{}}
	if err = prepareCommandOptions(c, &o); err != nil {
		t.Fatal(err)
	}
	if o.public["NC_TOPOLOGY_LOWERCASE"] != "false" || o.public["NC_TOPOLOGY_ABBREVIATE"] != "true" {
		t.Fatalf("explicit values lost: %v", o.public)
	}
}
func TestTFTPCheckRejectsMissingServer(t *testing.T) {
	r, out, diag := fixtureRuntime(t)
	r.Args = []string{"config", "check", "--for", "tftp"}
	if code := r.Run(t.Context()); code != 2 || !strings.Contains(diag.String(), "tftp.server") {
		t.Fatalf("code=%d out=%s diag=%s", code, out, diag)
	}
}

func TestTFTPPlanDoesNotRequireArchiveRoot(t *testing.T) {
	r, out, diag := fixtureRuntime(t)
	r.Args = []string{"backup", "plan", "--method", "tftp", "--tftp-server", "192.0.2.9", "--all", "--json"}
	r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) {
		return []inventory.Device{{IP: "192.0.2.1", Vendor: "h3c"}}, nil
	})
	if code := r.Run(t.Context()); code != 0 || !strings.Contains(out.String(), "192.0.2.1") {
		t.Fatalf("code=%d out=%s diag=%s", code, out, diag)
	}
}
func TestQuietInventoryMachineOutput(t *testing.T) {
	r, out, diag := fixtureRuntime(t)
	r.Args = []string{"inventory", "list", "--json", "--quiet"}
	r.Source = netdisco.SourceFunc(func(context.Context) ([]inventory.Device, error) {
		return []inventory.Device{{IP: "192.0.2.1", Vendor: "h3c"}}, nil
	})
	if code := r.Run(t.Context()); code != 0 || diag.Len() != 0 || !strings.HasPrefix(out.String(), "{") {
		t.Fatalf("code=%d out=%s diag=%s", code, out, diag)
	}
}

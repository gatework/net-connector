package cli

import (
	"bytes"
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"go.yaml.in/yaml/v3"

	"github.com/gatework/net-connector/config"
)

func TestDefaultsIgnoreConfigurationAndCredentials(t *testing.T) {
	for _, scope := range []string{"backup", "tftp", "topology"} {
		for _, jsonOutput := range []bool{false, true} {
			args := []string{"config", "defaults", "--for", scope, "--config", "/missing/config.yml", "--env-file", "/missing/credentials.env"}
			if jsonOutput {
				args = append(args, "--json")
			}
			var output, diagnostic bytes.Buffer
			r := Runtime{Args: args, Input: panicReader{}, Output: &output, Error: &diagnostic,
				CWD: "/missing/start", Home: "/missing/home", Environment: map[string]string{"NC_PARALLEL": "invalid", "NC_TFTP_UPLOAD_TIMEOUT": "invalid", "ND_PASSWORD": "PRIVATE_VALUE"}}
			if code := r.Run(t.Context()); code != 0 || diagnostic.Len() != 0 {
				t.Fatalf("scope=%s json=%v code=%d stderr=%s", scope, jsonOutput, code, &diagnostic)
			}
			var got, want map[string]any
			if jsonOutput {
				if err := json.Unmarshal(output.Bytes(), &got); err != nil {
					t.Fatal(err)
				}
				body, _ := json.Marshal(config.Defaults(scope))
				_ = json.Unmarshal(body, &want)
			} else {
				if err := yaml.Unmarshal(output.Bytes(), &got); err != nil {
					t.Fatal(err)
				}
				want = config.Defaults(scope)
			}
			if !reflect.DeepEqual(got, want) || strings.Contains(output.String(), "PRIVATE_VALUE") {
				t.Fatalf("unexpected defaults: %s", &output)
			}
		}
	}
}

func TestDefaultsRejectInvalidScopeAndOutputFailure(t *testing.T) {
	var diagnostic bytes.Buffer
	for _, args := range [][]string{{"config", "defaults", "--for", "invalid"}, {"config", "defaults", "extra"}} {
		if code := (Runtime{Args: args, Input: panicReader{}, Output: &bytes.Buffer{}, Error: &diagnostic}).Run(t.Context()); code != 2 {
			t.Fatal(code)
		}
	}
	for _, args := range [][]string{{"config", "defaults"}, {"config", "defaults", "--json"}} {
		if code := (Runtime{Args: args, Input: panicReader{}, Output: shortCommandWriter{}, Error: &diagnostic}).Run(t.Context()); code == 0 {
			t.Fatal("short output accepted")
		}
	}
}

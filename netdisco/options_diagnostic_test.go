package netdisco

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/gatework/net-connector/archive"
	"github.com/gatework/net-connector/transfer"
)

func TestCredentialOptionDiagnostics(t *testing.T) {
	pool := archive.PoolOptions{Root: "ssh://user@example.test/var/tftp", Directory: "/tmp/archive", WorkerPath: "/opt/worker", Parallel: 2, Password: "SECRET_PROBE"}
	http := HTTPOptions{URL: "https://example.test", Username: "user", Password: "SECRET_PROBE", APIKey: "APIKEY_PROBE"}
	postgres := PostgresOptions{Connection: "host=localhost user=test password=SECRET_PROBE", Query: "select $1", Parameters: []any{"PARAM_PROBE"}}
	malformedHTTP := HTTPOptions{URL: "https://user:SECRET_PROBE@example.test/SECRET_PROBE?token=APIKEY_PROBE#PARAM_PROBE"}
	malformedPG := PostgresOptions{Connection: "invalid SECRET_PROBE", Query: "SELECT 'SECRET_PROBE'", Parameters: []any{"PARAM_PROBE"}}
	remote := transfer.RemoteOptions{Server: "example.test", Path: "config", Username: "user", Protocol: "scp", Password: "SECRET_PROBE"}
	for _, value := range []any{pool, &pool, http, &http, malformedHTTP, &malformedHTTP, malformedPG, &malformedPG, postgres, &postgres, remote, &remote} {
		for _, format := range []string{"%v", "%+v", "%#v"} {
			assertSafeOptions(t, fmt.Sprintf(format, value))
		}
		b, err := json.Marshal(map[string]any{"nested": []any{value}})
		if err != nil {
			t.Fatal(err)
		}
		assertSafeOptions(t, string(b))
	}
	p, err := NewPostgres(postgres)
	if err != nil || p.connection.Password != "SECRET_PROBE" || p.parameters[0] != "PARAM_PROBE" {
		t.Fatal("postgres execution options changed", err)
	}
	h, err := NewHTTP(http)
	if err != nil || h.password != "SECRET_PROBE" || h.key != "APIKEY_PROBE" {
		t.Fatal("http execution options changed", err)
	}
	for _, value := range []any{pool, http, remote} {
		b, e := json.Marshal(value)
		if e != nil {
			t.Fatal(e)
		}
		if !strings.Contains(string(b), "example.test") {
			t.Fatalf("operational endpoint missing: %s", b)
		}
	}
	if remote.Password != "SECRET_PROBE" || pool.Password != "SECRET_PROBE" {
		t.Fatal("options mutated")
	}
}
func assertSafeOptions(t *testing.T, s string) {
	t.Helper()
	for _, secret := range []string{"SECRET_PROBE", "APIKEY_PROBE", "PARAM_PROBE"} {
		if strings.Contains(s, secret) {
			t.Errorf("credential in diagnostics: %s", s)
		}
	}
}

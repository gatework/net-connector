package bootstrap

import (
	"context"
	"errors"
	"path/filepath"
	"testing"

	"github.com/gatework/net-connector/config"
	"github.com/gatework/net-connector/netdisco"
)

func TestInventoryReturnsPostgresConstructorError(t *testing.T) {
	policy, err := config.Load(context.Background(), config.Options{
		Name: "backup", CWD: t.TempDir(), Home: t.TempDir(), Directories: []string{},
		Defaults: config.Defaults("backup"),
		Environment: map[string]string{
			"ND_SOURCE":         "postgres",
			"ND_QUERY":          "SELECT '192.0.2.1' AS ip",
			"ND_CACHE_ENABLED":  "false",
			"ND_DB_SSLMODE":     "verify-full",
			"ND_DB_SSLROOTCERT": filepath.Join(t.TempDir(), "missing-ca.pem"),
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	credentials := map[string]string{"ND_DB_HOST": "192.0.2.1", "ND_DB_NAME": "inventory", "ND_DB_USER": "reader", "ND_DB_PASS": "test-password"}
	services, err := New(policy, func(key string) string { return credentials[key] })
	if err != nil {
		t.Fatal(err)
	}
	_, err = services.Inventory(t.Context(), "refresh")
	var inventoryError *netdisco.InventoryError
	if !errors.As(err, &inventoryError) || inventoryError.Code != "invalid_connection" {
		t.Fatalf("expected constructor invalid_connection error, got %v", err)
	}
}

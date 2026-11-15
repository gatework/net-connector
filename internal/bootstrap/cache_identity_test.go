package bootstrap

import (
	"context"
	"errors"
	"testing"

	"github.com/gatework/net-connector/config"
	"github.com/gatework/net-connector/netdisco"
)

func TestAPICacheRequiresNonSecretNamespace(t *testing.T) {
	for _, namespace := range []string{"", "inventory-account"} {
		t.Run(namespace, func(t *testing.T) {
			environment := map[string]string{
				"ND_SOURCE": "http", "ND_URL": "https://inventory.example", "ND_CACHE_ENABLED": "true",
				"ND_CACHE_NAMESPACE": namespace,
			}
			policy, err := config.Load(context.Background(), config.Options{
				Name: "backup", CWD: t.TempDir(), Home: t.TempDir(), Directories: []string{},
				Defaults:    config.Defaults("backup"),
				Environment: environment,
			})
			if err != nil {
				t.Fatal(err)
			}
			services, err := New(policy, func(key string) string {
				if key == "ND_API_KEY" {
					return "private-api-key"
				}
				return ""
			})
			if err != nil {
				t.Fatal(err)
			}
			_, err = services.Inventory(t.Context(), "only")
			var inventoryError *netdisco.InventoryError
			wantCode := "cache_namespace_required"
			if namespace != "" {
				wantCode = "cache_unavailable"
			}
			if !errors.As(err, &inventoryError) || inventoryError.Code != wantCode {
				t.Fatalf("expected %s, got %v", wantCode, err)
			}
		})
	}
}

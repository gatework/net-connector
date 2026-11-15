package bootstrap

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/gatework/net-connector/config"
)

func inventoryServices(t *testing.T, root string, environment map[string]string) (*Services, error) {
	t.Helper()
	p, err := config.Load(context.Background(), config.Options{Name: "backup", CWD: root, Home: root, Directories: []string{}, Environment: environment, Defaults: config.Defaults("backup"), AllowMissing: true})
	if err != nil {
		t.Fatal(err)
	}
	return New(p, nil)
}

func TestFileInventoryIsReadWithoutNetdiscoSettings(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "devices.csv"), []byte("ip,vendor\n192.0.2.1,H3C\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	s, err := inventoryServices(t, root, map[string]string{"NC_INVENTORY_SOURCE": "file", "NC_INVENTORY_FILE": "devices.csv"})
	if err != nil {
		t.Fatal(err)
	}
	result, err := s.Inventory(t.Context(), "")
	if err != nil || len(result.Rows) != 1 || result.Rows[0].IP != "192.0.2.1" {
		t.Fatalf("file inventory: %+v %v", result.Rows, err)
	}
	if entries, _ := os.ReadDir(filepath.Join(root, ".cache")); len(entries) != 0 {
		t.Fatal("a file inventory was written to the cache")
	}
}

func TestFileInventoryConfigurationIsValidatedOffline(t *testing.T) {
	for _, tt := range []struct {
		name        string
		environment map[string]string
		field       string
	}{
		{"file source without a file", map[string]string{"NC_INVENTORY_SOURCE": "file"}, "inventory.file"},
		{"file source mixed with a netdisco url", map[string]string{"NC_INVENTORY_SOURCE": "file", "NC_INVENTORY_FILE": "devices.csv", "ND_URL": "https://inventory.example/api"}, "inventory.source"},
		{"unknown source", map[string]string{"NC_INVENTORY_SOURCE": "spreadsheet"}, "inventory.source"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			s, err := inventoryServices(t, t.TempDir(), tt.environment)
			if err == nil {
				err = s.validateInventorySource()
			}
			var field *config.FieldError
			if !errors.As(err, &field) || field.Field != tt.field {
				t.Fatalf("error = %v, want field %s", err, tt.field)
			}
		})
	}
}

package workflow_test

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/gatework/net-connector/config"
	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/internal/bootstrap"
	"github.com/gatework/net-connector/internal/workflow"
	"github.com/gatework/net-connector/inventory"
)

func TestTFTPPreflightFailureNeverCreatesDevice(t *testing.T) {
	root := t.TempDir()
	blocked := filepath.Join(root, "not-a-directory")
	if err := os.WriteFile(blocked, []byte("blocked"), 0600); err != nil {
		t.Fatal(err)
	}
	defaults := config.Defaults("tftp")
	defaults["backup"].(map[string]any)["directory"] = filepath.Join(root, "backups")
	defaults["tftp"].(map[string]any)["server"] = "192.0.2.10"
	defaults["tftp"].(map[string]any)["verification_root"] = blocked
	p, err := config.Load(context.Background(), config.Options{Name: "backup", CWD: root, Home: root, Directories: []string{}, Environment: map[string]string{}, Defaults: defaults, AllowMissing: true})
	if err != nil {
		t.Fatal(err)
	}
	s, err := bootstrap.New(p, nil)
	if err != nil {
		t.Fatal(err)
	}
	s = s.WithDeviceFactory(func(connector.Driver, connector.ConnectionConfig) (*connector.Device, error) {
		t.Fatal("device created before preflight succeeded")
		return nil, nil
	})
	settings, err := s.WorkflowTFTPSettings()
	if err != nil {
		t.Fatal(err)
	}
	r := &workflow.Runner{}
	_, err = r.TFTP(t.Context(), s.WorkflowRuntime(), settings, []inventory.Device{{IP: "192.0.2.1", Vendor: "h3c", Name: "edge"}}, workflow.TFTPOptions{BackupOptions: workflow.BackupOptions{Policy: "selected"}})
	if !errors.Is(err, workflow.ErrTFTPArchivePreflight) {
		t.Fatalf("unclassified preflight failure: %v", err)
	}
}

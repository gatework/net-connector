package bootstrap

import (
	"context"
	"testing"

	"github.com/gatework/net-connector/config"
)

func TestValidateTFTPUsesDefaultUploadTimeout(t *testing.T) {
	snapshot, err := config.Load(context.Background(), config.Options{
		Name:        "backup",
		CWD:         t.TempDir(),
		Home:        t.TempDir(),
		Directories: []string{},
		Defaults:    config.Defaults("backup"),
		Environment: map[string]string{"NC_TFTP_HOST": "192.0.2.50"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := ValidateTFTP(snapshot, "selected"); err != nil {
		t.Fatal(err)
	}
}

func TestValidateTFTPAcceptsVendorScopedSourceFile(t *testing.T) {
	snapshot, err := config.Load(context.Background(), config.Options{
		Name:        "backup",
		CWD:         t.TempDir(),
		Home:        t.TempDir(),
		Directories: []string{},
		Defaults:    config.Defaults("backup"),
		Environment: map[string]string{
			"NC_TFTP_HOST":         "192.0.2.50",
			"NC_TFTP_SOURCE_FILES": `{"huawei":{"default":"flash:/startup.cfg"}}`,
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := ValidateTFTP(snapshot, "selected"); err != nil {
		t.Fatal(err)
	}
}

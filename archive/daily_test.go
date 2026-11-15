package archive

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/gatework/net-connector/transfer"
)

func TestDailyArchiveLatestAndFailedUploadPreservesPrevious(t *testing.T) {
	root := t.TempDir()
	root, _ = filepath.EvalSymlinks(root)
	local := t.TempDir()
	day := time.Now().In(time.FixedZone("UTC+8", 8*3600)).Format("2006-01-02")
	want := filepath.Join(root, "archive", day, "edge-192.0.2.1.cfg")
	for _, content := range []string{"first configuration", "latest configuration"} {
		c, e := NewClient(ClientOptions{Root: root, Directory: local, Launcher: LocalLauncher()})
		if e != nil {
			t.Fatal(e)
		}
		if e = c.Prepare(t.Context()); e != nil {
			t.Fatal(e)
		}
		receipt, e := c.Upload(t.Context(), "edge.cfg", "edge-192.0.2.1.cfg", func(context.Context, string) (transfer.Receipt, error) {
			if e := os.WriteFile(filepath.Join(root, "edge.cfg"), []byte(content), 0600); e != nil {
				t.Fatal(e)
			}
			return transfer.Receipt{Path: "edge.cfg", Verification: "device_reported"}, nil
		})
		if e != nil {
			t.Fatal(e)
		}
		if receipt.Receipt.Server.ArchivePath != want || !receipt.Receipt.Verified() {
			t.Fatal(receipt)
		}
		c.Close()
	}
	c, _ := NewClient(ClientOptions{Root: root, Directory: local, Launcher: LocalLauncher()})
	defer c.Close()
	if e := c.Prepare(t.Context()); e != nil {
		t.Fatal(e)
	}
	_, e := c.Upload(t.Context(), "edge.cfg", "edge-192.0.2.1.cfg", func(context.Context, string) (transfer.Receipt, error) { return transfer.Receipt{}, ErrArchive })
	if e == nil {
		t.Fatal("failed upload accepted")
	}
	b, e := os.ReadFile(want)
	if e != nil || string(b) != "latest configuration" {
		t.Fatal(string(b), e)
	}
	entries, e := os.ReadDir(filepath.Join(root, "archive"))
	if e != nil || len(entries) != 1 || entries[0].Name() != day {
		t.Fatal(entries, e)
	}
}
func TestDailyDateValidation(t *testing.T) {
	for _, s := range []string{"../escape", "2026-99-01", "2026-02-30", "2026-1-01"} {
		if dailyBatch(s) {
			t.Fatal(s)
		}
	}
}

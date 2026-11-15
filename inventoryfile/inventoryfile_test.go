package inventoryfile

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/gatework/net-connector/inventory"
)

func write(t *testing.T, name, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestReadAcceptsYAMLAndCSVWithTheSameFields(t *testing.T) {
	expected := []inventory.Device{
		{IP: "192.0.2.1", Name: "core-1", Vendor: "Cisco", OS: "ios", Model: "WS-C3750G", OSVersion: "12.2(55)SE9", Serial: "FOC1234X5YZ"},
		{IP: "2001:db8::2", Vendor: "H3C"},
	}
	for name, body := range map[string]string{
		"devices.yml": "devices:\n  - ip: 192.0.2.1\n    name: core-1\n    vendor: Cisco\n    os: ios\n    model: WS-C3750G\n    os_ver: \"12.2(55)SE9\"\n    serial: FOC1234X5YZ\n  - ip: \"2001:DB8::2\"\n    vendor: H3C\n",
		"devices.csv": "\xef\xbb\xbfIP, name, vendor, os, model, os_ver, serial\r\n192.0.2.1,core-1,Cisco,ios,WS-C3750G,12.2(55)SE9,FOC1234X5YZ\r\n2001:DB8::2,,H3C,,,,\r\n",
	} {
		t.Run(name, func(t *testing.T) {
			got, err := Read(t.Context(), write(t, name, body))
			if err != nil || len(got) != len(expected) {
				t.Fatalf("devices = %+v, %v", got, err)
			}
			for i := range expected {
				if got[i] != expected[i] {
					t.Errorf("device %d = %+v, want %+v", i, got[i], expected[i])
				}
			}
		})
	}
}

func TestReadRejectsTheWholeFileWithALocatedError(t *testing.T) {
	for _, tt := range []struct {
		name, file, body string
		entry            int
		field            string
	}{
		{"unusable address", "a.csv", "ip\n192.0.2.1\nnot-an-address\n", 2, "ip"},
		{"scoped address", "a.csv", "ip\nfe80::1%eth0\n", 1, "ip"},
		{"missing address", "a.yml", "devices:\n  - name: core\n", 1, "ip"},
		{"address with leading zeros", "a.csv", "ip\n192.0.2.1\n192.000.2.1\n", 2, "ip"},
		{"repeated address", "a.csv", "ip\n192.0.2.1\n192.0.2.1\n", 2, "ip"},
		{"repeated address in another spelling", "a.yml", "devices:\n  - ip: \"2001:db8::1\"\n  - ip: \"2001:DB8:0::1\"\n", 2, "ip"},
		{"unknown csv column", "a.csv", "ip,hostname\n192.0.2.1,core\n", 0, ""},
		{"repeated csv column", "a.csv", "ip,name,name\n192.0.2.1,a,b\n", 0, ""},
		{"csv without ip column", "a.csv", "name\ncore\n", 0, ""},
		{"csv row with a missing field", "a.csv", "ip,name\n192.0.2.1,core\n192.0.2.2\n", 2, "row"},
		{"unknown yaml key", "a.yml", "devices:\n  - ip: 192.0.2.1\n    hostname: core\n", 1, "key"},
		{"yaml value that is not text", "a.yml", "devices:\n  - ip: 192.0.2.1\n    serial: 12345\n", 1, "serial"},
		{"yaml entry that is not a mapping", "a.yml", "devices:\n  - 192.0.2.1\n", 1, "entry"},
		{"yaml with another root key", "a.yml", "devices: []\nhosts: []\n", 0, ""},
		{"yaml without a devices list", "a.yml", "devices: core\n", 0, ""},
		{"unsupported extension", "a.txt", "192.0.2.1\n", 0, ""},
	} {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Read(t.Context(), write(t, tt.file, tt.body))
			var located *FileError
			if got != nil || !errors.Is(err, ErrFile) || !errors.As(err, &located) || located.Entry != tt.entry || located.Field != tt.field {
				t.Fatalf("devices=%v err=%v", got, err)
			}
		})
	}
}

func TestReadErrorNeverEchoesFileContent(t *testing.T) {
	_, err := Read(t.Context(), write(t, "a.csv", "ip,name\nprivate-token-value,core\n"))
	if err == nil || strings.Contains(err.Error(), "private-token-value") {
		t.Fatalf("error exposes file content: %v", err)
	}
}

func TestReadUsesTheBoundedFileReader(t *testing.T) {
	directory := t.TempDir()
	if _, err := Read(t.Context(), filepath.Join(directory, "missing.yml")); !errors.Is(err, ErrFile) {
		t.Fatalf("missing file: %v", err)
	}
	fifo := filepath.Join(directory, "pipe.csv")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Skip("cannot create a FIFO:", err)
	}
	if _, err := Read(t.Context(), fifo); !errors.Is(err, ErrFile) {
		t.Fatalf("a FIFO was read as an inventory: %v", err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	cancel()
	if _, err := Read(ctx, write(t, "a.csv", "ip\n192.0.2.1\n")); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled read: %v", err)
	}
}

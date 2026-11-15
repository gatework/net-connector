package cli

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/gatework/net-connector/internal/workflow"
	"github.com/gatework/net-connector/vendors"
)

func TestPlatformListMatchesDeclaredCapabilities(t *testing.T) {
	rows, err := workflow.PlatformCapabilities(vendors.NewBuiltinRegistry())
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]workflow.Capabilities{}
	for _, row := range rows {
		got[row.Platform] = row
	}
	for name, expected := range map[string]workflow.Capabilities{
		"h3c":     {Platform: "h3c", ConfigCollection: true, Save: true, ReadOnlyCommands: true, Facts: true, NeighborDiscovery: true, DescriptionRead: true, InterfaceIdentity: true, DescriptionWrite: true, TFTP: true},
		"juniper": {Platform: "juniper", ConfigCollection: true, Commit: true, ReadOnlyCommands: true, Facts: true, NeighborDiscovery: true, DescriptionRead: true, InterfaceIdentity: true, RemoteBackup: true},
		"radware": {Platform: "radware", ConfigCollection: true, Save: true, ReadOnlyCommands: true, DescriptionRead: true, InterfaceIdentity: true, TFTP: true},
		"topsec":  {Platform: "topsec", ConfigCollection: true, ReadOnlyCommands: true},
	} {
		if got[name] != expected {
			t.Errorf("%s capabilities = %+v, want %+v", name, got[name], expected)
		}
	}
	if len(rows) != 12 {
		t.Fatalf("platform count = %d, want 12", len(rows))
	}

	var text bytes.Buffer
	if err = renderPlatforms(&text, rows, false); err != nil {
		t.Fatal(err)
	}
	if lines := strings.Split(strings.TrimSpace(text.String()), "\n"); len(lines) != 13 || !strings.HasPrefix(lines[1], "centec") {
		t.Fatalf("text listing:\n%s", text.String())
	}
	var encoded bytes.Buffer
	if err = renderPlatforms(&encoded, rows, true); err != nil {
		t.Fatal(err)
	}
	var decoded struct{ Platforms []workflow.Capabilities }
	if err = json.Unmarshal(encoded.Bytes(), &decoded); err != nil || len(decoded.Platforms) != 12 {
		t.Fatalf("json listing: %v %s", err, encoded.String())
	}
}

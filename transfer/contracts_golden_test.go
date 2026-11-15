package transfer_test

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/gatework/net-connector/transfer"
)

func TestGoldenTransferCommandsAndReplies(t *testing.T) {
	var fixture struct {
		Transfers map[string]struct {
			Path     string
			Source   *string
			Commands []struct {
				Text      string
				Timeout   float64
				Responses []string
			}
		}
	}
	b, e := os.ReadFile("../testdata/device-contracts.json")
	if e != nil {
		t.Fatal(e)
	}
	if e = json.Unmarshal(b, &fixture); e != nil {
		t.Fatal(e)
	}
	for vendor, want := range fixture.Transfers {
		t.Run(vendor, func(t *testing.T) {
			source := ""
			if want.Source != nil {
				source = *want.Source
			}
			command := tftpPolicyForTest(t, vendor).Command("192.0.2.1", transfer.TFTPOptions{Server: "192.0.2.9", Path: want.Path, SourceFile: source, Timeout: 180 * time.Second}, true)
			if len(want.Commands) != 1 {
				t.Fatal("command count changed")
			}
			w := want.Commands[0]
			responses := []string{}
			for _, i := range command.Interactions {
				responses = append(responses, i.Reply)
			}
			if command.Text != w.Text || command.Timeout == nil || *command.Timeout != time.Duration(w.Timeout*float64(time.Second)) || !reflect.DeepEqual(responses, w.Responses) {
				t.Fatalf("command differs: %s %v", command.Text, responses)
			}
		})
	}
}

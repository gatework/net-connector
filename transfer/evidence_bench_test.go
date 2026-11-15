package transfer

import (
	"fmt"
	"strings"
	"testing"

	"github.com/gatework/net-connector/connector"
)

func BenchmarkEvidence(b *testing.B) {
	for _, size := range []int{64 << 10, 1 << 20, 16 << 20} {
		b.Run(fmt.Sprintf("bytes=%d", size), func(b *testing.B) {
			line := "Interface Ethernet1 telemetry progress 73 percent\r"
			output := strings.Repeat(line, size/len(line)+1)[:size]
			steps := []evidenceStep{{command: connector.Command{Text: "show configuration"}, prompt: "switch#", output: output}}
			b.SetBytes(int64(size))
			b.ReportAllocs()
			for b.Loop() {
				_, _, err := collectEvidence(steps, failed)
				if err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

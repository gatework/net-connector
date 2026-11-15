package vendors

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/gatework/net-connector/connector"
)

func BenchmarkRunningConfig(b *testing.B) {
	for _, size := range []int{1 << 20, 8 << 20} {
		b.Run(fmt.Sprintf("%dKiB", size>>10), func(b *testing.B) {
			const line = "interface Ethernet1\r\n description uplink\r\n!\r\n"
			body := "show running-config\r\nBuilding configuration...\r\n" + strings.Repeat(line, size/len(line)) + "end\r\nsw#"
			p := lookupPlatform(b, "cisco_ios")
			done := make(chan struct{})
			d, err := connector.New(p, connector.ConnectionConfig{Host: "fixture", MaxOutputBytes: int64(len(body) + 1024), CommandTimeout: 30 * time.Second},
				connector.WithTransportFactory(func(context.Context, connector.ConnectionConfig) (io.ReadWriteCloser, error) {
					a, peer := net.Pipe()
					go func() {
						defer close(done)
						defer peer.Close()
						if _, err := io.WriteString(peer, "sw#"); err != nil {
							return
						}
						r := bufio.NewReader(peer)
						for {
							command, err := r.ReadString('\n')
							if err != nil {
								return
							}
							response := "sw#"
							if command == "show running-config\n" {
								response = body
							}
							if _, err := io.WriteString(peer, response); err != nil {
								return
							}
						}
					}()
					return a, nil
				}))
			if err != nil {
				b.Fatal(err)
			}
			b.Cleanup(func() { _ = d.Close(); <-done })
			if err := d.Connect(b.Context()); err != nil {
				b.Fatal(err)
			}
			b.ReportAllocs()
			b.SetBytes(int64(len(body)))
			for b.Loop() {
				result, err := d.RunningConfig(b.Context())
				if err != nil {
					b.Fatal(err)
				}
				if config, ok := result.Config(); !ok || len(config) < size/2 {
					b.Fatal("missing configuration")
				}
			}
		})
	}
}

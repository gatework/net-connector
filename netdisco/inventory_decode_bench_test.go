package netdisco

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/gatework/net-connector/inventory"
)

func benchmarkInventoryBody(count int) []byte {
	rows := make([]inventory.Device, count)
	for i := range rows {
		rows[i] = inventory.Device{IP: fmt.Sprintf("10.%d.%d.%d", i>>16, i>>8&255, i&255), Name: "switch", DNS: "switch.example.test", Vendor: "cisco", OS: "ios", Model: "fixture", OSVersion: "1.0", Serial: "fixture"}
	}
	body, _ := json.Marshal(rows)
	return body
}

func BenchmarkHTTPInventoryDecode(b *testing.B) {
	for _, count := range []int{500, 10000, 100000} {
		b.Run(fmt.Sprint(count), func(b *testing.B) {
			body := benchmarkInventoryBody(count)
			b.ReportAllocs()
			b.SetBytes(int64(len(body)))
			for b.Loop() {
				seen := 0
				rows, err := decodeHTTPInventory(b.Context(), body, count, &seen)
				if err != nil || len(rows) != count {
					b.Fatal(err)
				}
			}
		})
	}
}

func BenchmarkHTTPInventoryLocal(b *testing.B) {
	for _, count := range []int{500, 10000, 100000} {
		b.Run(fmt.Sprint(count), func(b *testing.B) {
			body := string(benchmarkInventoryBody(count))
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Query().Get("offset") == "0" {
					io.Copy(w, strings.NewReader(body))
				} else {
					io.WriteString(w, "[]")
				}
			}))
			defer server.Close()
			source, err := NewHTTP(HTTPOptions{URL: server.URL, APIKey: "fixture", Client: server.Client(), Limits: Limits{PageSize: count, MaxDevices: count, MaxResponseBytes: 64 << 20}})
			if err != nil {
				b.Fatal(err)
			}
			b.ReportAllocs()
			for b.Loop() {
				rows, err := source.Devices(b.Context())
				if err != nil || len(rows) != count {
					b.Fatal(err)
				}
			}
		})
	}
}

func BenchmarkPostgresMapping(b *testing.B) {
	fields := []pgconn.FieldDescription{{Name: "ip"}, {Name: "name"}, {Name: "dns"}, {Name: "vendor"}, {Name: "os"}, {Name: "model"}, {Name: "os_ver"}, {Name: "serial"}}
	values := [][]byte{[]byte("192.0.2.1"), []byte("switch"), []byte("switch.example.test"), []byte("cisco"), []byte("ios"), []byte("fixture"), []byte("1.0"), []byte("fixture")}
	limits, _ := (Limits{}).normalize()
	for _, count := range []int{500, 10000, 100000} {
		b.Run(fmt.Sprint(count), func(b *testing.B) {
			b.ReportAllocs()
			for b.Loop() {
				var total int64
				for offset := 0; offset < count; offset += 500 {
					columns, err := postgresColumns(b.Context(), fields)
					if err != nil {
						b.Fatal(err)
					}
					var response int64
					for range min(500, count-offset) {
						row, err := decodePostgresRow(b.Context(), columns, values, limits, &response, &total)
						if err != nil || row.IP != "192.0.2.1" {
							b.Fatal(err)
						}
					}
				}
			}
		})
	}
}

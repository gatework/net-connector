package netdisco

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"

	"github.com/gatework/net-connector/inventory"
)

type inventoryRoundTripFunc func(*http.Request) (*http.Response, error)

func (f inventoryRoundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestHTTPDecodeMatchesLegacyBoundary(t *testing.T) {
	for _, body := range []string{
		`[]`, ` `, `null`, `[null]`, `{}`, `[{"name":"missing"}]`,
		`[{"ip":null}]`, `[{"ip":" \t "}]`, `[{"ip":12}]`, `[{"ip":true}]`,
		`[{"ip":"x","name":null,"serial":null}]`,
		`[{"ip":"x","IP":"ignored","Name":"ignored","OS_VER":"ignored","unknown":{"x":1}}]`,
		`[{"IP":"x"}]`, `[{"ip":"x","name":42}]`, `[{"ip":"x","name":{}}]`,
		`[{"ip":"first","ip":"last","name":"first","name":null}]`,
		`[{"ip":null,"ip":"last","name":"\ud800","serial":"\u0000"}]`,
		`[{"ip":"first","ip":null}]`, `[{"ip":"x"},{"ip":"x"}]`,
		`[{"ip":"x","name":"\ud83d\ude00","dns":"a\\b","vendor":"H3C","os":"comware","model":"<>&","os_ver":"1","serial":"s"}]`,
		"[{\"ip\":\"x\",\"name\":\"\xff\xfe\"}]",
	} {
		t.Run(fmt.Sprintf("%q", body), func(t *testing.T) {
			count := 0
			want, wantErr := legacyDecodeHTTPInventory([]byte(body), 100, &count)
			if wantErr == nil {
				want, _ = dedupContext(context.Background(), want)
			}
			client := &http.Client{Transport: inventoryRoundTripFunc(func(r *http.Request) (*http.Response, error) {
				response := body
				if r.URL.Query().Get("offset") != "0" {
					response = `[]`
				}
				return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(response)), Header: make(http.Header)}, nil
			})}
			source, err := NewHTTP(HTTPOptions{URL: "http://inventory.test", APIKey: "fixture", Client: client, Limits: Limits{MaxDevices: 100}})
			if err != nil {
				t.Fatal(err)
			}
			got, gotErr := source.Devices(context.Background())
			if !reflect.DeepEqual(got, want) || errorCodeOrEmpty(gotErr) != errorCodeOrEmpty(wantErr) {
				t.Fatalf("got %#v, %v; want %#v, %v", got, gotErr, want, wantErr)
			}
		})
	}
}

func errorCodeOrEmpty(err error) string {
	if err == nil {
		return ""
	}
	return errorCode(err)
}

func TestPostgresMappingMatchesLegacyBoundary(t *testing.T) {
	fields := []pgconn.FieldDescription{{Name: "ip"}, {Name: "name"}, {Name: "unknown"}, {Name: "IP"}}
	columns, err := postgresColumns(t.Context(), fields)
	if err != nil {
		t.Fatal(err)
	}
	for _, ip := range [][]byte{nil, {}, []byte(" \t"), []byte("192.0.2.1"), {0xff, 0xfe}} {
		for _, name := range [][]byte{nil, {}, []byte("<>&\x00😀"), {0xff, 0xfe, 0xe2, 0x82}} {
			for _, budget := range []int64{2, 30, 1000} {
				limits := Limits{MaxResponseBytes: budget, MaxInventoryBytes: 1000}
				for range 2 {
					values := [][]byte{ip, name, []byte("ignored-budget"), []byte("ignored-case")}
					var response, total, oldResponse, oldTotal int64
					got, gotErr := decodePostgresRow(t.Context(), columns, values, limits, &response, &total)
					want, wantErr := legacyDecodePostgresRow(fields, values, limits, &oldResponse, &oldTotal)
					if got != want || errorCodeOrEmpty(gotErr) != errorCodeOrEmpty(wantErr) || response != oldResponse || total != oldTotal {
						t.Fatalf("values=%q limits=%+v: got=%+v/%v/%d/%d want=%+v/%v/%d/%d", values, limits, got, gotErr, response, total, want, wantErr, oldResponse, oldTotal)
					}
					limits.MaxResponseBytes, limits.MaxInventoryBytes = limits.MaxInventoryBytes, limits.MaxResponseBytes
				}
			}
		}
	}
	for _, fields := range [][]pgconn.FieldDescription{
		{{Name: "IP"}}, {{Name: "name"}}, {{Name: "ip"}, {Name: "ip"}}, {{Name: "ip"}, {Name: "unknown"}, {Name: "unknown"}},
	} {
		if _, err := postgresColumns(t.Context(), fields); errorCode(err) != "invalid_inventory" {
			t.Fatalf("accepted columns: %v: %v", fields, err)
		}
	}
	values := [][]byte{[]byte("192.0.2.1"), []byte("switch"), nil, nil}
	limits, _ := (Limits{}).normalize()
	var response, total int64
	row, err := decodePostgresRow(t.Context(), columns, values, limits, &response, &total)
	if err != nil {
		t.Fatal(err)
	}
	for _, value := range values {
		clear(value)
	}
	if row.IP != "192.0.2.1" || row.Name != "switch" {
		t.Fatal("row retained driver-owned bytes")
	}
}

// Cancel at a deterministic CPU checkpoint, after some fields/rows were mapped.
type mappingCancelContext struct {
	context.Context
	cancel    context.CancelFunc
	remaining int
}

func (c *mappingCancelContext) Err() error {
	c.remaining--
	if c.remaining == 0 {
		c.cancel()
	}
	return c.Context.Err()
}

func TestInventoryMappingCancellationReturnsNoPartialResult(t *testing.T) {
	newContext := func(checks int) context.Context {
		ctx, cancel := context.WithCancel(t.Context())
		t.Cleanup(cancel)
		return &mappingCancelContext{ctx, cancel, checks}
	}
	seen := 0
	rows, err := decodeHTTPInventory(newContext(12), []byte(`[{"ip":"one"},{"ip":"two"}]`), 100, &seen)
	if rows != nil || !errors.Is(err, context.Canceled) {
		t.Fatalf("HTTP partial result: %v %v", rows, err)
	}
	rows, err = dedupContext(newContext(2), []inventory.Device{{IP: "one"}, {IP: "two"}})
	if rows != nil || !errors.Is(err, context.Canceled) {
		t.Fatalf("dedup partial result: %v %v", rows, err)
	}
	columns, err := postgresColumns(newContext(2), []pgconn.FieldDescription{{Name: "ip"}, {Name: "name"}})
	if columns != nil || !errors.Is(err, context.Canceled) {
		t.Fatalf("columns partial result: %v %v", columns, err)
	}
	columns, err = postgresColumns(t.Context(), []pgconn.FieldDescription{{Name: "ip"}, {Name: "name"}})
	if err != nil {
		t.Fatal(err)
	}
	limits, _ := (Limits{}).normalize()
	var response, total int64
	row, err := decodePostgresRow(newContext(2), columns, [][]byte{[]byte("one"), []byte("switch")}, limits, &response, &total)
	if row != (inventory.Device{}) || !errors.Is(err, context.Canceled) {
		t.Fatalf("PG partial result: %v %v", row, err)
	}
}

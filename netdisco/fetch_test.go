package netdisco

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gatework/net-connector/inventory"
)

func TestFetchHTTPCacheEvidence(t *testing.T) {
	var fail atomic.Bool
	var calls atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if fail.Load() {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		if r.URL.Query().Get("offset") == "0" {
			io.WriteString(w, `[{"ip":"192.0.2.1"}]`)
		} else {
			io.WriteString(w, `[]`)
		}
	}))
	defer server.Close()
	directory := filepath.Join(t.TempDir(), "cache")
	now := time.Unix(1000, 0)
	ttl := time.Hour
	cache := &CachePolicy{Directory: directory, Namespace: "account-a", TTL: &ttl, Now: func() time.Time { return now }}
	source := HTTPOptions{URL: server.URL + "/", APIKey: "private-key"}
	if _, err := FetchHTTP(t.Context(), source, FetchOptions{Mode: "only", Cache: cache}); (errorCode(err) != "cache_unavailable" || !errors.Is(err, ErrCacheRefreshRequired)) || calls.Load() != 0 {
		t.Fatalf("cache-only without an entry must require refresh: %v calls=%d", err, calls.Load())
	}
	result, err := FetchHTTP(t.Context(), source, FetchOptions{Cache: cache})
	if err != nil || result.Status != CacheStatusRefreshed || len(result.Rows) != 1 || result.Rows[0].IP != "192.0.2.1" || !result.FetchedAt.Equal(now) {
		t.Fatalf("new refresh: %+v %v", result, err)
	}
	source.URL = strings.TrimSuffix(source.URL, "/")
	source.APIKey = "rotated-key"
	result, err = FetchHTTP(t.Context(), source, FetchOptions{Mode: "only", Cache: cache})
	if err != nil || result.Status != CacheStatusFresh || calls.Load() != 2 {
		t.Fatalf("canonical URL and explicit account survive key rotation: %+v %v", result, err)
	}
	now = now.Add(2 * time.Hour)
	fail.Store(true)
	result, err = FetchHTTP(t.Context(), source, FetchOptions{Mode: "refresh", Cache: cache})
	if err != nil || result.Status != CacheStatusStale || result.RefreshErrorCode != "request_failed" || !result.FetchedAt.Equal(time.Unix(1000, 0)) {
		t.Fatalf("stale evidence lost: %+v %v", result, err)
	}
	files, err := filepath.Glob(filepath.Join(directory, "*.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, file := range files {
		body, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		for _, secret := range []string{"private-key", "rotated-key", fmt.Sprintf("%x", sha256.Sum256([]byte("private-key")))} {
			if strings.Contains(string(body)+file, secret) {
				t.Fatal("cache disclosed key material")
			}
		}
	}
}

func TestFetchHTTPPrincipalsAndQueryShape(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/login" {
			io.WriteString(w, `{"api_key":"issued-key"}`)
		} else {
			io.WriteString(w, `[]`)
		}
	}))
	defer server.Close()
	for _, auth := range []string{"key", "named_key", "basic"} {
		t.Run(auth, func(t *testing.T) {
			cache := &CachePolicy{Directory: filepath.Join(t.TempDir(), "cache")}
			source := HTTPOptions{URL: server.URL, APIKey: "original-key"}
			if auth != "key" {
				source.Username = "account-a"
			}
			if auth == "basic" {
				source.APIKey, source.Password = "", "password"
			}
			if _, err := FetchHTTP(t.Context(), source, FetchOptions{Cache: cache}); err != nil {
				t.Fatal(err)
			}
			source.Limits.PageSize = 500 // Explicit default must share the same cache.
			if _, err := FetchHTTP(t.Context(), source, FetchOptions{Mode: "only", Cache: cache}); err != nil {
				t.Fatal(err)
			}
			source.Password = "" // cache-only basic auth must not require the password.
			if source.APIKey != "" {
				source.APIKey = "rotated-key"
			}
			_, err := FetchHTTP(t.Context(), source, FetchOptions{Mode: "only", Cache: cache})
			if auth == "key" {
				if errorCode(err) != "cache_unavailable" || !errors.Is(err, ErrCacheRefreshRequired) {
					t.Fatalf("anonymous key rotation must invalidate the principal: %v", err)
				}
				return
			}
			if err != nil {
				t.Fatal("named principal changed with credential", err)
			}
			for _, change := range []string{"account", "namespace", "query"} {
				t.Run(change, func(t *testing.T) {
					changed, changedCache := source, *cache
					switch change {
					case "account":
						changed.Username = "account-b"
					case "namespace":
						changedCache.Namespace = "different-account"
					case "query":
						changed.Limits.PageSize = 100
					}
					if _, err := FetchHTTP(t.Context(), changed, FetchOptions{Mode: "only", Cache: &changedCache}); errorCode(err) != "cache_unavailable" || !errors.Is(err, ErrCacheRefreshRequired) {
						t.Fatal("changed source must not reuse cache", err)
					}
				})
			}
		})
	}
}

func TestFetchHTTPWriteFailureAndOwnership(t *testing.T) {
	closed := make(chan struct{}, 1)
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { io.WriteString(w, `[]`) }))
	server.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		if state == http.StateClosed {
			select {
			case closed <- struct{}{}:
			default:
			}
		}
	}
	server.Start()
	defer server.Close()
	result, err := FetchHTTP(t.Context(), HTTPOptions{URL: server.URL, APIKey: "key"}, FetchOptions{})
	if err != nil || result.Status != CacheStatusDisabled {
		t.Fatal(result, err)
	}
	select {
	case <-closed:
	case <-time.After(5 * time.Second):
		t.Fatal("owned idle connection was retained after FetchHTTP")
	}
	borrowed := &fetchTransport{}
	cache := &CachePolicy{Directory: filepath.Join(t.TempDir(), "cache")}
	source := HTTPOptions{URL: "https://inventory.example", APIKey: "key", Client: &http.Client{Transport: borrowed}}
	u, limits, err := httpSettings(source, true)
	if err != nil {
		t.Fatal(err)
	}
	identity, err := httpIdentity(source, u.String(), limits, "")
	if err != nil {
		t.Fatal(err)
	}
	borrowed.before = func() {
		if err := os.Mkdir(filepath.Join(cache.Directory, identity+".json"), 0700); err != nil {
			t.Fatal(err)
		}
	}
	result, err = FetchHTTP(t.Context(), source, FetchOptions{Mode: "refresh", Cache: cache})
	if err != nil || result.Status != CacheStatusRefreshed || result.Rows == nil || result.WriteErrorType != "IOError" || result.FetchedAt.IsZero() || borrowed.closed {
		t.Fatalf("write or ownership evidence lost: %+v %v closed=%v", result, err, borrowed.closed)
	}
}

type fetchTransport struct {
	before func()
	closed bool
}

func (t *fetchTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	if t.before != nil {
		t.before()
	}
	return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(`[]`)), Header: make(http.Header), Request: request}, nil
}
func (t *fetchTransport) CloseIdleConnections() { t.closed = true }

func TestFetchPostgresEffectiveIdentityOffline(t *testing.T) {
	t.Setenv("PGHOST", "database-a.example")
	t.Setenv("PGUSER", "reader")
	t.Setenv("PGDATABASE", "inventory")
	t.Setenv("PGSSLMODE", "disable")
	source := PostgresOptions{Connection: "password=original", Query: "select ip from device where vendor = $1", Parameters: []any{"Cisco"}}
	postgres, err := NewPostgres(source)
	if err != nil {
		t.Fatal(err)
	}
	identity, err := postgresIdentity(postgres, "account")
	if err != nil {
		t.Fatal(err)
	}
	policy := &CachePolicy{Directory: filepath.Join(t.TempDir(), "cache"), Namespace: "account"}
	cache, err := newCache(SourceFunc(func(context.Context) ([]inventory.Device, error) { return []inventory.Device{{IP: "192.0.2.1"}}, nil }), cacheOptions{Directory: policy.Directory}, identity)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := cache.Fetch(t.Context(), "refresh"); err != nil {
		t.Fatal(err)
	}
	source.Connection = "host=database-a.example port=5432 user=reader dbname=inventory sslmode=disable password=rotated"
	result, err := FetchPostgres(t.Context(), source, FetchOptions{Mode: "only", Cache: policy})
	if err != nil || result.Status != CacheStatusFresh || len(result.Rows) != 1 {
		t.Fatalf("equivalent effective source did not share cache: %+v %v", result, err)
	}
	source.Connection = ""
	t.Setenv("PGHOST", "database-b.example")
	if _, err := FetchPostgres(t.Context(), source, FetchOptions{Mode: "only", Cache: policy}); errorCode(err) != "cache_unavailable" || !errors.Is(err, ErrCacheRefreshRequired) {
		t.Fatal("effective environment source must isolate caches", err)
	}
	t.Setenv("PGHOST", "database-a.example")
	source.Parameters = []any{"H3C"}
	if _, err := FetchPostgres(t.Context(), source, FetchOptions{Mode: "only", Cache: policy}); errorCode(err) != "cache_unavailable" || !errors.Is(err, ErrCacheRefreshRequired) {
		t.Fatal("query parameters must isolate caches", err)
	}
}

func TestHTTPIdentityCanonicalizationPreservesZoneAndRequestPath(t *testing.T) {
	for _, test := range []struct{ input, want string }{
		{"http://INVENTORY.EXAMPLE/base/", "http://inventory.example/base"},
		{"http://[FE80::1%25ZoneA]:8080/base/", "http://[fe80::1%25ZoneA]:8080/base"},
		{"https://inventory.example/base%20path//", "https://inventory.example/base%20path"},
	} {
		source, err := NewHTTP(HTTPOptions{URL: test.input, APIKey: "key"})
		if err != nil {
			t.Fatal(err)
		}
		source.CloseIdleConnections()
		if source.base.String() != test.want {
			t.Fatalf("normalized URL=%q want=%q", source.base.String(), test.want)
		}
	}
}

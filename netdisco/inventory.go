// Package netdisco provides bounded inventory sources and their cache.
package netdisco

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/gatework/net-connector/inventory"
)

// Source provides complete bounded inventory rows for one fetch.
type Source interface {
	Devices(ctx context.Context) ([]inventory.Device, error)
}

// SourceFunc adapts a function into an inventory source.
type SourceFunc func(context.Context) ([]inventory.Device, error)

// Devices fetches inventory within the source limits and context.
func (f SourceFunc) Devices(ctx context.Context) ([]inventory.Device, error) { return f(ctx) }

// InventoryError classifies an inventory failure while preserving its private cause.
type InventoryError struct {
	Code  string
	cause error
}

func (e *InventoryError) Error() string { return "netdisco: " + e.Code }

// GoString formats safe operational metadata without credentials.
func (e *InventoryError) GoString() string { return e.Error() }

// Unwrap returns the underlying failure for error classification.
func (e *InventoryError) Unwrap() error            { return e.cause }
func newInventoryError(code string, e error) error { return &InventoryError{code, e} }

// Limits bounds inventory requests, pagination, response size and duration.
type Limits struct {
	PageSize, MaxPages, MaxDevices      int
	MaxResponseBytes, MaxInventoryBytes int64
	Timeout                             time.Duration
}

func (l Limits) normalize() (Limits, error) {
	if l.PageSize < 0 || l.MaxPages < 0 || l.MaxDevices < 0 || l.MaxResponseBytes < 0 || l.MaxInventoryBytes < 0 || l.Timeout < 0 {
		return l, newInventoryError("invalid_limits", nil)
	}
	if l.PageSize == 0 {
		l.PageSize = 500
	}
	if l.MaxPages == 0 {
		l.MaxPages = 10000
	}
	if l.MaxDevices == 0 {
		l.MaxDevices = 100000
	}
	if l.MaxResponseBytes == 0 {
		l.MaxResponseBytes = 16 << 20
	}
	if l.MaxInventoryBytes == 0 {
		l.MaxInventoryBytes = 128 << 20
	}
	if l.Timeout == 0 {
		l.Timeout = 300 * time.Second
	}
	return l, nil
}

// HTTPOptions defines an HTTP inventory source and optional borrowed client.
type HTTPOptions struct {
	URL, Username, Password, APIKey string
	RequireHTTPS                    bool
	Client                          *http.Client
	Limits                          Limits
}

// HTTP fetches bounded inventory over HTTP without exposing credentials in formatting.
type HTTP struct {
	base                    *url.URL
	username, password, key string
	client                  *http.Client
	limits                  Limits
	ownedTransport          *http.Transport
}

// NewHTTP validates settings and creates an HTTP source with explicit transport ownership.
func NewHTTP(o HTTPOptions) (*HTTP, error) {
	u, limits, e := httpSettings(o, true)
	if e != nil {
		return nil, e
	}
	client := o.Client
	var transport *http.Transport
	if client == nil {
		// A custom DefaultTransport is borrowed: only a transport we cloned is ours.
		client = &http.Client{Transport: http.DefaultTransport}
		if standard, ok := http.DefaultTransport.(*http.Transport); ok {
			transport = standard.Clone()
			client.Transport = transport
		}
	}
	ownedClient := *client
	ownedClient.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return &HTTP{base: u, username: o.Username, password: o.Password, key: o.APIKey, client: &ownedClient, limits: limits, ownedTransport: transport}, nil
}

func httpSettings(o HTTPOptions, requirePassword bool) (*url.URL, Limits, error) {
	u, e := url.Parse(o.URL)
	if e != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") || u.User != nil || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || (o.RequireHTTPS && u.Scheme != "https") {
		return nil, Limits{}, newInventoryError("invalid_url", nil)
	}
	if strings.ContainsAny(o.APIKey, "\r\n\x00") || strings.ContainsAny(o.Username, "\r\n\x00:") {
		return nil, Limits{}, newInventoryError("invalid_credentials", nil)
	}
	if o.APIKey == "" && (o.Username == "" || requirePassword && o.Password == "") {
		return nil, Limits{}, newInventoryError("missing_credentials", nil)
	}
	limits, e := o.Limits.normalize()
	if e != nil {
		return nil, Limits{}, e
	}
	u.Scheme, u.Host = strings.ToLower(u.Scheme), canonicalHost(u.Host)
	u.Path, u.RawPath = strings.TrimRight(u.Path, "/"), ""
	return u, limits, nil
}

func canonicalHost(host string) string {
	// IPv6 zone identifiers name local interfaces and may be case-sensitive.
	if zone := strings.IndexByte(host, '%'); zone >= 0 {
		return strings.ToLower(host[:zone]) + host[zone:]
	}
	return strings.ToLower(host)
}

// CloseIdleConnections releases connections created by this source. Injected
// clients and custom default transports are borrowed and are never closed.
func (h *HTTP) CloseIdleConnections() {
	if h.ownedTransport != nil {
		h.ownedTransport.CloseIdleConnections()
	}
}

const httpInventoryEndpoint = "api/v1/search/device"
const httpInventoryFields = "ip,name,dns,vendor,os,model,os_ver,serial"
const httpFallbackQuery = "%"

func (h *HTTP) String() string { return "netdisco.HTTP" }

// GoString formats safe operational metadata without credentials.
func (h *HTTP) GoString() string { return h.String() }

// Devices fetches inventory within the source limits and context.
func (h *HTTP) Devices(parent context.Context) ([]inventory.Device, error) {
	ctx, cancel := context.WithTimeout(parent, h.limits.Timeout)
	defer cancel()
	r := &httpInventoryRun{source: h, seen: make(map[string]bool), unique: make(map[inventory.Device]bool), rows: make([]inventory.Device, 0)}
	key, err := r.authenticate(ctx)
	if err != nil {
		return nil, err
	}
	for page := range h.limits.MaxPages {
		data, complete, err := r.page(ctx, page, key)
		if err != nil {
			return nil, err
		}
		if complete {
			return data, nil
		}
		if len(data) == 0 {
			if err := ctx.Err(); err != nil {
				return nil, newInventoryError("inventory_timeout", err)
			}
			return r.rows, nil
		}
		if err := r.accept(ctx, data); err != nil {
			return nil, err
		}
	}
	return nil, newInventoryError("max_pages", nil)
}

type httpInventoryRun struct {
	source *HTTP
	total  int64
	count  int
	seen   map[string]bool
	unique map[inventory.Device]bool
	rows   []inventory.Device
}

func (r *httpInventoryRun) request(ctx context.Context, endpoint, method string, query url.Values, key string) ([]byte, int, error) {
	u := *r.source.base
	u.Path = strings.TrimRight(u.Path, "/") + "/" + endpoint
	u.RawQuery = query.Encode()
	req, e := http.NewRequestWithContext(ctx, method, u.String(), nil)
	if e != nil {
		return nil, 0, newInventoryError("request_failed", e)
	}
	req.Header.Set("Accept", "application/json")
	if key != "" {
		req.Header.Set("Authorization", "Apikey "+key)
	} else {
		req.SetBasicAuth(r.source.username, r.source.password)
	}
	resp, e := r.source.client.Do(req)
	if e != nil {
		return nil, 0, newInventoryError("connection_failed", e)
	}
	defer resp.Body.Close()
	limit := min(r.source.limits.MaxResponseBytes, r.source.limits.MaxInventoryBytes-r.total)
	b, e := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if e != nil {
		return nil, resp.StatusCode, newInventoryError("connection_failed", e)
	}
	r.total += int64(len(b))
	if r.total > r.source.limits.MaxInventoryBytes {
		return nil, resp.StatusCode, newInventoryError("max_inventory_bytes", nil)
	}
	if int64(len(b)) > r.source.limits.MaxResponseBytes {
		return nil, resp.StatusCode, newInventoryError("max_response_bytes", nil)
	}
	if e = ctx.Err(); e != nil {
		return nil, 0, newInventoryError("inventory_timeout", e)
	}
	return b, resp.StatusCode, nil
}

func (r *httpInventoryRun) authenticate(ctx context.Context) (string, error) {
	key := r.source.key
	if key == "" {
		b, status, e := r.request(ctx, "login", http.MethodPost, nil, "")
		if e != nil {
			return "", e
		}
		if status < 200 || status >= 300 {
			return "", newInventoryError("request_failed", nil)
		}
		var data struct {
			APIKey string `json:"api_key"`
		}
		if e = json.Unmarshal(b, &data); e != nil || data.APIKey == "" || strings.ContainsAny(data.APIKey, "\r\n\x00") {
			return "", newInventoryError("authentication_failed", nil)
		}
		key = data.APIKey
	}

	return key, nil
}

func (r *httpInventoryRun) page(ctx context.Context, page int, key string) ([]inventory.Device, bool, error) {
	query := url.Values{"fields": {httpInventoryFields}, "limit": {strconv.Itoa(r.source.limits.PageSize)}, "offset": {strconv.Itoa(page * r.source.limits.PageSize)}}
	body, status, e := r.request(ctx, httpInventoryEndpoint, http.MethodGet, query, key)
	if e != nil {
		return nil, false, e
	}
	if status == 400 {
		var message struct {
			Error string `json:"error"`
		}
		if json.Unmarshal(body, &message) == nil && message.Error == "Missing query" {
			body, status, e = r.request(ctx, httpInventoryEndpoint, http.MethodGet, url.Values{"q": {httpFallbackQuery}, "seeallcolumns": {"true"}}, key)
			if e != nil {
				return nil, false, e
			}
			if status < 200 || status >= 300 {
				return nil, false, newInventoryError("request_failed", nil)
			}
			data, e := decodeHTTPInventory(ctx, body, r.source.limits.MaxDevices, &r.count)
			if e != nil {
				return nil, false, e
			}
			rows, err := dedupContext(ctx, data)
			return rows, true, err
		}
	}
	if status < 200 || status >= 300 {
		return nil, false, newInventoryError("request_failed", fmt.Errorf("HTTP %d", status))
	}
	rows, err := decodeHTTPInventory(ctx, body, r.source.limits.MaxDevices, &r.count)
	return rows, false, err
}

func (r *httpInventoryRun) accept(ctx context.Context, data []inventory.Device) error {
	advances := false
	for _, row := range data {
		if e := ctx.Err(); e != nil {
			return newInventoryError("inventory_timeout", e)
		}
		if !r.seen[row.IP] {
			advances = true
		}
		r.seen[row.IP] = true
		if !r.unique[row] {
			r.unique[row] = true
			r.rows = append(r.rows, row)
		}
	}
	if !advances {
		return newInventoryError("pagination_stalled", nil)
	}
	return nil
}

func dedupContext(ctx context.Context, rows []inventory.Device) ([]inventory.Device, error) {
	seen := make(map[inventory.Device]bool)
	out := make([]inventory.Device, 0, len(rows))
	for _, r := range rows {
		if e := ctx.Err(); e != nil {
			return nil, newInventoryError("inventory_timeout", e)
		}
		if !seen[r] {
			out = append(out, r)
			seen[r] = true
		}
	}
	if e := ctx.Err(); e != nil {
		return nil, newInventoryError("inventory_timeout", e)
	}
	return out, nil
}

var inventoryFieldNames = [...]string{"ip", "name", "dns", "vendor", "os", "model", "os_ver", "serial"}

func inventoryFields(d *inventory.Device) [8]*string {
	return [8]*string{&d.IP, &d.Name, &d.DNS, &d.Vendor, &d.OS, &d.Model, &d.OSVersion, &d.Serial}
}

func decodeHTTPInventory(ctx context.Context, b []byte, maxDevices int, count *int) ([]inventory.Device, error) {
	if e := ctx.Err(); e != nil {
		return nil, newInventoryError("inventory_timeout", e)
	}
	if len(strings.TrimSpace(string(b))) == 0 {
		return []inventory.Device{}, nil
	}
	if !utf8.Valid(b) {
		return nil, newInventoryError("invalid_json", nil)
	}
	// Raw-message maps keep acceptance case-sensitive and retain JSON's last-key-wins behavior.
	var data []map[string]json.RawMessage
	if e := json.Unmarshal(b, &data); e != nil || data == nil {
		return nil, newInventoryError("invalid_inventory", e)
	}
	*count += len(data)
	if *count > maxDevices {
		return nil, newInventoryError("max_devices", nil)
	}
	rows := make([]inventory.Device, len(data))
	for i, row := range data {
		if e := ctx.Err(); e != nil {
			return nil, newInventoryError("inventory_timeout", e)
		}
		if row == nil {
			return nil, newInventoryError("invalid_inventory", nil)
		}
		fields := inventoryFields(&rows[i])
		for j, name := range inventoryFieldNames {
			if e := ctx.Err(); e != nil {
				return nil, newInventoryError("inventory_timeout", e)
			}
			value, ok := row[name]
			if !ok {
				continue
			}
			// Unmarshaling null into an empty string preserves optional null-as-empty fields.
			if e := json.Unmarshal(value, fields[j]); e != nil {
				return nil, newInventoryError("invalid_inventory", nil)
			}
		}
		if strings.TrimSpace(rows[i].IP) == "" {
			return nil, newInventoryError("invalid_inventory", nil)
		}
	}
	if e := ctx.Err(); e != nil {
		return nil, newInventoryError("inventory_timeout", e)
	}
	return rows, nil
}

func errorCode(e error) string {
	if ie, ok := errors.AsType[*InventoryError](e); ok {
		return ie.Code
	}
	if errors.Is(e, context.DeadlineExceeded) {
		return "inventory_timeout"
	}
	return "inventory_error"
}

// MarshalJSON exposes operational metadata only; credentials remain available explicitly on the options.
func (o HTTPOptions) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		URL, Username string
		RequireHTTPS  bool
		Limits        Limits
	}{safeOptionURL(o.URL), o.Username, o.RequireHTTPS, o.Limits})
}
func (o HTTPOptions) String() string { b, _ := o.MarshalJSON(); return "HTTPOptions" + string(b) }

// GoString formats safe operational metadata without credentials.
func (o HTTPOptions) GoString() string { return o.String() }

func safeOptionURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return "[invalid URL]"
	}
	return u.Scheme + "://" + u.Host
}

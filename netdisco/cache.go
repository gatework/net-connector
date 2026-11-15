package netdisco

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/storage"

	"golang.org/x/sys/unix"
)

type cacheOptions struct {
	Directory   string
	TTL         *time.Duration
	LockTimeout time.Duration
	Limits      Limits
	Now         func() time.Time
}

// Cache result statuses exposed to callers.
const (
	CacheStatusRefreshed = "refreshed"
	CacheStatusFresh     = "fresh_cache"
	CacheStatusStale     = "stale_cache"
	CacheStatusDisabled  = "disabled"
)

type cache struct {
	source                              Source
	directory, identity, path, lockPath string
	ttl, lockTimeout                    time.Duration
	limits                              Limits
	now                                 func() time.Time
}

// CacheResult contains complete rows. Status records whether data was
// refreshed, read fresh/stale from cache, or fetched with caching disabled.
// cache-only Fetch reports freshness; source failures use Go errors unless a
// validated stale entry is available.
type CacheResult struct {
	Rows                                     []inventory.Device
	Status, RefreshErrorCode, WriteErrorType string
	FetchedAt                                time.Time
}
type cacheEntry struct {
	Schema    int                `json:"schema"`
	Identity  string             `json:"identity"`
	FetchedAt float64            `json:"fetched_at"`
	Rows      []inventory.Device `json:"rows"`
}

// ErrCacheRefreshRequired marks cache-only reads without a validated entry for
// the requested identity. InventoryError.Code remains cache_unavailable.
var ErrCacheRefreshRequired = errors.New("netdisco: refresh this source before using cache-only mode")

func newCache(source Source, o cacheOptions, identity string) (*cache, error) {
	if o.Directory == "" || strings.ContainsRune(o.Directory, 0) {
		return nil, newInventoryError("invalid_cache", nil)
	}
	limits, e := o.Limits.normalize()
	if e != nil {
		return nil, e
	}
	ttl := 72 * time.Hour
	if o.TTL != nil {
		ttl = *o.TTL
	}
	if ttl < 0 || o.LockTimeout < 0 {
		return nil, newInventoryError("invalid_cache", nil)
	}
	lockTimeout := o.LockTimeout
	if lockTimeout == 0 {
		lockTimeout = 5 * time.Second
	}
	now := o.Now
	if now == nil {
		now = time.Now
	}
	directory, e := filepath.Abs(o.Directory)
	if e != nil {
		return nil, e
	}
	return &cache{source, directory, identity, filepath.Join(directory, identity+".json"), filepath.Join(directory, identity+".lock"), ttl, lockTimeout, limits, now}, nil
}
func (c *cache) Fetch(ctx context.Context, mode CacheMode) (result CacheResult, err error) {
	if !mode.Valid() {
		return result, newInventoryError("invalid_cache_mode", nil)
	}
	if c.source == nil && mode != CacheOnly {
		return result, newInventoryError("cache_unavailable", nil)
	}
	if e := ctx.Err(); e != nil {
		return result, e
	}
	if mode != CacheOnly {
		if e := os.MkdirAll(c.directory, 0700); e != nil {
			return result, e
		}
	}
	directory, e := os.Lstat(c.directory)
	if mode == CacheOnly && errors.Is(e, os.ErrNotExist) {
		return result, newInventoryError("cache_unavailable", ErrCacheRefreshRequired)
	}
	if e != nil || !isPrivateCacheEntry(directory, true) {
		return result, newInventoryError("cache_unavailable", nil)
	}
	defer func() {
		after, e := os.Lstat(c.directory)
		if err == nil && (e != nil || !os.SameFile(directory, after)) {
			err = newInventoryError("cache_directory_changed", nil)
		}
	}()
	return c.fetchEntries(ctx, mode)
}

func (c *cache) fetchEntries(ctx context.Context, mode CacheMode) (result CacheResult, err error) {
	previous, _, e := c.read(ctx)
	if e != nil {
		return result, e
	}
	fresh := func(entry *cacheEntry) bool {
		return entry != nil && c.now().Sub(time.Unix(0, int64(entry.FetchedAt*1e9))) < c.ttl
	}
	deliver := func(entry *cacheEntry, status string) CacheResult {
		return CacheResult{Rows: append([]inventory.Device{}, entry.Rows...), Status: status, FetchedAt: time.Unix(0, int64(entry.FetchedAt*1e9)).UTC()}
	}
	if mode == CacheOnly {
		if previous == nil {
			return result, newInventoryError("cache_unavailable", ErrCacheRefreshRequired)
		}
		status := CacheStatusStale
		if fresh(previous) {
			status = CacheStatusFresh
		}
		return deliver(previous, status), nil
	}
	if mode == CachePrefer && fresh(previous) {
		return deliver(previous, CacheStatusFresh), nil
	}
	lock, e := storage.AcquireLockFile(ctx, c.lockPath, c.lockTimeout)
	if e != nil {
		return result, e
	}
	defer func() {
		if e := lock.Close(); err == nil && e != nil {
			err = e
		}
	}()
	previous, _, e = c.read(ctx)
	if e != nil {
		return result, e
	}
	if mode == CachePrefer && fresh(previous) {
		return deliver(previous, CacheStatusFresh), nil
	}
	rows, e := c.source.Devices(ctx)
	if e == nil {
		e = c.validateRows(rows)
	}
	if ctx.Err() != nil {
		return result, ctx.Err()
	}
	if e != nil {
		if previous == nil {
			return result, e
		}
		result = deliver(previous, CacheStatusStale)
		result.RefreshErrorCode = errorCode(e)
		return result, nil
	}
	entry := cacheEntry{Schema: 1, Identity: c.identity, FetchedAt: float64(c.now().UnixNano()) / 1e9, Rows: append([]inventory.Device{}, rows...)}
	result = deliver(&entry, CacheStatusRefreshed)
	body, e := json.Marshal(entry)
	if e == nil && int64(len(body)) > c.limits.MaxInventoryBytes {
		e = newInventoryError("max_inventory_bytes", nil)
	}
	if e == nil {
		_, e = storage.Write(ctx, c.path, body)
	}
	if e != nil {
		result.WriteErrorType = "IOError"
	}
	return result, nil
}
func isPrivateCacheEntry(info os.FileInfo, directory bool) bool {
	if info == nil {
		return false
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok || st.Uid != uint32(os.Geteuid()) {
		return false
	}
	if directory {
		return info.IsDir() && info.Mode().Perm() == 0700
	}
	return info.Mode().IsRegular() && info.Mode().Perm() == 0600 && st.Nlink == 1
}

// read loads the cache entry. found is false on a cache miss: no entry, an
// oversized but private entry, or one that does not decode or validate for
// this identity. An unsafe entry is an error, not a miss.
func (c *cache) read(ctx context.Context) (entry *cacheEntry, found bool, err error) {
	body, fp, e := storage.Read(ctx, c.path, c.limits.MaxInventoryBytes)
	if errors.Is(e, os.ErrNotExist) {
		return nil, false, nil
	}
	if errors.Is(e, storage.ErrLimit) {
		// Reopen without following links: only a private regular entry is a cache miss.
		fd, openErr := unix.Open(c.path, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
		if openErr != nil {
			return nil, false, newInventoryError("cache_unavailable", openErr)
		}
		file := os.NewFile(uintptr(fd), c.path)
		info, statErr := file.Stat()
		closeErr := file.Close()
		if statErr != nil || closeErr != nil || !isPrivateCacheEntry(info, false) || !storage.SameEntry(c.path, storage.Fingerprint{Info: info}) {
			return nil, false, newInventoryError("cache_unavailable", nil)
		}
		if e := ctx.Err(); e != nil {
			return nil, false, e
		}
		return nil, false, nil
	}
	if e != nil {
		return nil, false, newInventoryError("cache_unavailable", e)
	}
	if !isPrivateCacheEntry(fp.Info, false) || !storage.SameEntry(c.path, fp) {
		return nil, false, newInventoryError("cache_unavailable", nil)
	}
	var decoded cacheEntry
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&decoded) != nil {
		return nil, false, nil //nolint:nilerr // an undecodable entry is a cache miss
	}
	if !errors.Is(decoder.Decode(new(any)), io.EOF) {
		return nil, false, nil // trailing content is a cache miss
	}
	now := float64(c.now().UnixNano()) / 1e9
	if decoded.Schema != 1 || decoded.Identity != c.identity || math.IsNaN(decoded.FetchedAt) || math.IsInf(decoded.FetchedAt, 0) || decoded.FetchedAt < 0 || decoded.FetchedAt > now || decoded.Rows == nil {
		return nil, false, nil
	}
	if c.validateRows(decoded.Rows) != nil {
		return nil, false, nil //nolint:nilerr // invalid rows make the entry a cache miss
	}
	return &decoded, true, nil
}
func (c *cache) validateRows(rows []inventory.Device) error {
	if rows == nil || len(rows) > c.limits.MaxDevices {
		return newInventoryError("invalid_inventory", nil)
	}
	var size int64
	for _, r := range rows {
		if strings.TrimSpace(r.IP) == "" {
			return newInventoryError("invalid_inventory", nil)
		}
		size += int64(len(r.IP) + len(r.Name) + len(r.DNS) + len(r.Vendor) + len(r.OS) + len(r.Model) + len(r.OSVersion) + len(r.Serial) + 37)
		if size > c.limits.MaxInventoryBytes {
			return newInventoryError("max_inventory_bytes", nil)
		}
	}
	return nil
}

// digest returns the opaque hex SHA-256 of a canonical source descriptor.
func digest(descriptor []byte) string {
	sum := sha256.Sum256(descriptor)
	return hex.EncodeToString(sum[:])
}

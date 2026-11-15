package workflow

import (
	"context"
	"errors"
	"path/filepath"
	"strings"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/fleet"
	"github.com/gatework/net-connector/storage"
)

func (runtime Runtime) logDir(mode, directory string) string {
	if runtime.LogDirectory == nil {
		return ""
	}
	return runtime.LogDirectory(mode, directory)
}

func openDevice(ctx context.Context, runtime Runtime, r fleet.Record, logs string, observer SessionObserver) (*connector.Device, func() error, error) {
	if runtime.OpenDevice == nil {
		return nil, nil, errors.New("workflow: device opener is not configured")
	}
	if logs == "" {
		d, e := runtime.OpenDevice(ctx, r, nil, observer)
		if e != nil {
			return nil, nil, e
		}
		if d == nil {
			return nil, nil, errors.New("workflow: device opener returned a nil device")
		}
		return d, d.Close, nil
	}
	if e := storage.PrepareDirectory(logs); e != nil {
		return nil, nil, e
	}
	log, e := storage.OpenAppend(filepath.Join(logs, strings.ReplaceAll(r.Host, ":", "_")+".log"))
	if e != nil {
		return nil, nil, e
	}
	d, e := runtime.OpenDevice(ctx, r, log, observer)
	if e != nil {
		return nil, nil, joinDeviceCleanup(e, log.Close())
	}
	if d == nil {
		return nil, nil, joinDeviceCleanup(errors.New("workflow: device opener returned a nil device"), log.Close())
	}
	return d, func() error { return errors.Join(d.Close(), log.Sync(), log.Close()) }, nil
}

type deviceCleanupError struct{ cause error }

func (*deviceCleanupError) Error() string      { return "netman: operation or cleanup failed" }
func (e *deviceCleanupError) GoString() string { return e.Error() }
func (e *deviceCleanupError) Unwrap() error    { return e.cause }
func joinDeviceCleanup(primary, cleanup error) error {
	if cleanup == nil {
		return primary
	}
	return &deviceCleanupError{cause: errors.Join(primary, cleanup)}
}

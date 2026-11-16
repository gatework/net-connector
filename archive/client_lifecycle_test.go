package archive

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/gatework/net-connector/transfer"
)

func TestClientPrepareRejectsClosedBeforeSideEffects(t *testing.T) {
	for _, prepared := range []bool{false, true} {
		t.Run(map[bool]string{false: "new", true: "prepared"}[prepared], func(t *testing.T) {
			root, err := filepath.EvalSymlinks(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			directory := filepath.Join(t.TempDir(), "local")
			launch := LocalLauncher()
			launches := 0
			client, err := NewClient(ClientOptions{Root: root, Directory: directory, Launcher: func(ctx context.Context) (Channel, error) {
				launches++
				return launch(ctx)
			}})
			if err != nil {
				t.Fatal(err)
			}
			if prepared {
				if err := client.Prepare(t.Context()); err != nil {
					t.Fatal(err)
				}
				if err := os.RemoveAll(directory); err != nil {
					t.Fatal(err)
				}
			}
			if err := client.Close(); err != nil {
				t.Fatal(err)
			}
			before := launches
			if err := client.Prepare(t.Context()); !errors.Is(err, ErrArchive) {
				t.Errorf("closed Prepare = %v, want ErrArchive", err)
			}
			if launches != before {
				t.Error("closed Prepare launched a channel")
			}
			if _, err := os.Stat(directory); !errors.Is(err, os.ErrNotExist) {
				t.Errorf("closed Prepare created a directory: %v", err)
			}
		})
	}
}

func TestClientPrepareRejectsCanceledBeforeSideEffects(t *testing.T) {
	for _, prepared := range []bool{false, true} {
		t.Run(map[bool]string{false: "new", true: "prepared"}[prepared], func(t *testing.T) {
			root, err := filepath.EvalSymlinks(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			directory := filepath.Join(t.TempDir(), "local")
			launch := LocalLauncher()
			launches := 0
			client, err := NewClient(ClientOptions{Root: root, Directory: directory, Launcher: func(ctx context.Context) (Channel, error) {
				launches++
				return launch(ctx)
			}})
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			if prepared {
				if err := client.Prepare(t.Context()); err != nil {
					t.Fatal(err)
				}
				if err := os.RemoveAll(directory); err != nil {
					t.Fatal(err)
				}
			}
			ctx, cancel := context.WithCancel(t.Context())
			cancel()
			before := launches
			if err := client.Prepare(ctx); !errors.Is(err, context.Canceled) {
				t.Errorf("canceled Prepare = %v, want context.Canceled", err)
			}
			if launches != before {
				t.Error("canceled Prepare launched a channel")
			}
			if _, err := os.Stat(directory); !errors.Is(err, os.ErrNotExist) {
				t.Errorf("canceled Prepare created a directory: %v", err)
			}
		})
	}
}

func TestClientPrepareWaitCanCancel(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	client, err := NewClient(ClientOptions{Root: t.TempDir(), Directory: t.TempDir(), Launcher: func(context.Context) (Channel, error) { close(entered); <-release; return Channel{}, ErrArchive }})
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	first := make(chan error, 1)
	go func() { first <- client.Prepare(t.Context()) }()
	<-entered
	if err := client.Close(); !errors.Is(err, ErrArchive) {
		t.Error("active Prepare was not owned")
	}
	ctx, cancel := context.WithCancel(t.Context())
	second := make(chan error, 1)
	go func() { second <- client.Prepare(ctx) }()
	cancel()
	select {
	case err := <-second:
		if !errors.Is(err, context.Canceled) {
			t.Errorf("wait error %v", err)
		}
	case <-time.After(200 * time.Millisecond):
		t.Error("canceled Prepare remained behind network I/O")
	}
	close(release)
	<-first
}

func TestClientUploadAbnormalCallbackCancelsContext(t *testing.T) {
	for _, mode := range []string{"panic", "goexit"} {
		t.Run(mode, func(t *testing.T) {
			root, err := filepath.EvalSymlinks(t.TempDir())
			if err != nil {
				t.Fatal(err)
			}
			client, err := NewClient(ClientOptions{Root: root, Directory: t.TempDir(), Launcher: LocalLauncher()})
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			if err := client.Prepare(t.Context()); err != nil {
				t.Fatal(err)
			}
			callbackContexts := make(chan context.Context, 1)
			var recovered any
			done := make(chan struct{})
			go func() {
				defer close(done)
				defer func() { recovered = recover() }()
				_, _ = client.Upload(t.Context(), "running.cfg", "archive.cfg", func(ctx context.Context, _ string) (transfer.Receipt, error) {
					callbackContexts <- ctx
					if mode == "panic" {
						panic("upload stopped")
					}
					runtime.Goexit()
					return transfer.Receipt{}, nil
				})
			}()
			<-done
			if mode == "panic" && recovered != "upload stopped" {
				t.Fatalf("panic = %v", recovered)
			}
			callbackContext := <-callbackContexts
			if callbackContext == nil || !errors.Is(callbackContext.Err(), context.Canceled) {
				t.Fatalf("callback context not canceled after %s: %v", mode, callbackContext)
			}
			if err := client.Close(); err != nil {
				t.Fatal(err)
			}
		})
	}
}

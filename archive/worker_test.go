package archive

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/gatework/net-connector/transfer"
)

func TestWorkerTransactionAndUnconfirmedStaging(t *testing.T) {
	for _, cleanup := range []bool{false, true} {
		t.Run(fmt.Sprint(cleanup), func(t *testing.T) {
			root := t.TempDir()
			root, _ = filepath.EvalSymlinks(root)
			os.WriteFile(filepath.Join(root, "config.txt"), []byte("old"), 0600)
			client, server := net.Pipe()
			defer client.Close()
			done := make(chan error, 1)
			go func() { defer server.Close(); done <- Serve(context.Background(), server, server) }()
			reader := bufio.NewReader(client)
			writeRequest := func(v map[string]any) {
				t.Helper()
				v["version"] = Version
				v["timeouts"] = TimeoutBudget{Prepare: 1000, Upload: 1000, Verify: 1000, Cleanup: 1000}
				if e := json.NewEncoder(client).Encode(v); e != nil {
					t.Fatal(e)
				}
			}
			frame := func(phase string) map[string]any {
				t.Helper()
				line, e := reader.ReadBytes('\n')
				if e != nil {
					t.Fatal(e)
				}
				m := map[string]any{}
				if json.Unmarshal(line, &m) != nil || m["phase"] != phase || m["ok"] != true {
					t.Fatal(string(line))
				}
				return m
			}
			writeRequest(map[string]any{"root": root, "filename": "config.txt", "archive_name": "device.txt", "batch": "2026-10-25_12-00-00-ssh-0123456789abcdef"})
			frame("ready")
			data := []byte("new configuration\n")
			os.WriteFile(filepath.Join(root, "config.txt"), data, 0600)
			writeRequest(map[string]any{"action": "verify"})
			m := frame("archived")
			if m["sha256"] != fmt.Sprintf("%x", sha256.Sum256(data)) {
				t.Fatal(m)
			}
			body := make([]byte, len(data))
			if _, e := io.ReadFull(reader, body); e != nil || string(body) != string(data) {
				t.Fatal(e, string(body))
			}
			frame("delivered")
			if cleanup {
				writeRequest(map[string]any{"action": "cleanup", "sha256": m["sha256"]})
				frame("complete")
			} else {
				writeRequest(map[string]any{"action": "abort"})
			}
			if e := <-done; e != nil {
				t.Fatal(e)
			}
			_, e := os.Stat(filepath.Join(root, "config.txt"))
			if cleanup && !os.IsNotExist(e) || !cleanup && e != nil {
				t.Fatal(e)
			}
		})
	}
}
func TestWorkerPreflightAndUnsafePaths(t *testing.T) {
	root := t.TempDir()
	root, _ = filepath.EvalSymlinks(root)
	for _, name := range []string{"../escape", "a/b", "a\\b"} {
		c, s := net.Pipe()
		done := make(chan error, 1)
		go func() { defer s.Close(); done <- Serve(context.Background(), s, s) }()
		json.NewEncoder(c).Encode(map[string]any{"version": Version, "timeouts": TimeoutBudget{1000, 1000, 1000, 1000}, "root": root, "filename": name, "archive_name": "x", "batch": "2026-10-25-ssh-0123456789abcdef"})
		io.ReadAll(c)
		if e := <-done; e == nil {
			t.Fatal(name)
		}
		c.Close()
	}
}

func TestWorkerLocksCasefoldAliases(t *testing.T) {
	root := t.TempDir()
	root, _ = filepath.EvalSymlinks(root)
	first, err := NewClient(ClientOptions{Root: root, Directory: t.TempDir(), Launcher: LocalLauncher()})
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("NC_ARCHIVE_WORKER_SUBPROCESS", "1")
	second, err := NewClient(ClientOptions{Root: root, Directory: t.TempDir(), Launcher: CommandLauncher(os.Args[0], "-test.run=^TestWorkerSubprocess$")})
	if err != nil {
		t.Fatal(err)
	}
	if err := first.Prepare(context.Background()); err != nil {
		t.Fatal(err)
	}
	if err := second.Prepare(context.Background()); err != nil {
		t.Fatal(err)
	}
	started := make(chan struct{})
	release := make(chan struct{})
	defer func() {
		select {
		case <-release:
		default:
			close(release)
		}
	}()
	firstDone := make(chan error, 1)
	go func() {
		_, err := first.Upload(context.Background(), "Config.cfg", "first.cfg", func(context.Context, string) (transfer.Receipt, error) {
			close(started)
			<-release
			return transfer.Receipt{}, ErrArchive
		})
		firstDone <- err
	}()
	<-started
	secondEntered := make(chan struct{})
	secondDone := make(chan error, 1)
	go func() {
		_, err := second.Upload(context.Background(), "config.cfg", "second.cfg", func(context.Context, string) (transfer.Receipt, error) {
			close(secondEntered)
			return transfer.Receipt{}, ErrArchive
		})
		secondDone <- err
	}()
	select {
	case <-secondEntered:
		t.Fatal("alias entered while first target lock held")
	case <-time.After(100 * time.Millisecond):
	}
	close(release)
	<-firstDone
	select {
	case <-secondEntered:
	case <-time.After(time.Second):
		t.Fatal("second alias did not acquire lock")
	}
	<-secondDone
}

func TestWorkerSubprocess(t *testing.T) {
	if os.Getenv("NC_ARCHIVE_WORKER_SUBPROCESS") != "1" {
		return
	}
	if err := Serve(context.Background(), subprocessReader{os.Stdin}, subprocessWriter{os.Stdout}); err != nil {
		os.Exit(1)
	}
	os.Exit(0)
}

type subprocessReader struct{ io.Reader }
type subprocessWriter struct{ io.Writer }

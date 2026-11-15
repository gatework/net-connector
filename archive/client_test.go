package archive

import (
	"context"
	"io"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/gatework/net-connector/transfer"
)

func TestClientVerifiesBothArchivesBeforeCleanup(t *testing.T) {
	root := t.TempDir()
	root, _ = filepath.EvalSymlinks(root)
	local := t.TempDir()
	launch := func(ctx context.Context) (Channel, error) {
		c, s := net.Pipe()
		done := make(chan error, 1)
		go func() { e := Serve(ctx, s, s); s.Close(); done <- e }()
		return Channel{Input: c, Output: c, Close: func() error { c.Close(); <-done; return nil }}, nil
	}
	client, e := NewClient(ClientOptions{Root: root, Directory: local, Launcher: launch})
	if e != nil {
		t.Fatal(e)
	}
	if e = client.Prepare(context.Background()); e != nil {
		t.Fatal(e)
	}
	got, e := client.Upload(context.Background(), "running.txt", "device.txt", func(context.Context, string) (transfer.Receipt, error) {
		os.WriteFile(filepath.Join(root, "running.txt"), []byte("running config"), 0600)
		return transfer.Receipt{Server: "192.0.2.9", Path: "running.txt", Verification: "device_reported"}, nil
	})
	if e != nil || !got.Receipt.Verified() || got.Receipt.Local.Path == "" || got.Receipt.Server.ArchivePath == "" {
		t.Fatal(got, e)
	}
	b, e := os.ReadFile(got.Receipt.Local.Path)
	if e != nil || string(b) != "running config" {
		t.Fatal(e)
	}
	if _, e = os.Stat(filepath.Join(root, "running.txt")); !os.IsNotExist(e) {
		t.Fatal("staging not removed", e)
	}
}

type writerOnly struct{ io.Writer }
type readerOnly struct{ io.Reader }

func TestClientRejectsChannelWithoutDeadlinesBeforeIO(t *testing.T) {
	root := t.TempDir()
	root, _ = filepath.EvalSymlinks(root)
	closed := make(chan struct{})
	launcher := func(context.Context) (Channel, error) {
		client, server := net.Pipe()
		return Channel{Input: writerOnly{client}, Output: readerOnly{client}, Close: func() error {
			client.Close()
			server.Close()
			close(closed)
			return nil
		}}, nil
	}
	client, err := NewClient(ClientOptions{Root: root, Directory: t.TempDir(), Launcher: launcher})
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- client.Prepare(context.Background()) }()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("accepted unbounded channel")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("unbounded channel blocked Prepare")
	}
	select {
	case <-closed:
	default:
		t.Fatal("channel not closed")
	}
}

package archive

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gatework/net-connector/transfer"
)

func TestNewPoolValidationAndSlots(t *testing.T) {
	root := t.TempDir()
	root, _ = filepath.EvalSymlinks(root)
	for _, tc := range []struct {
		name string
		opts PoolOptions
	}{
		{"zero parallel", PoolOptions{Root: root, Directory: t.TempDir()}},
		{"over limit", PoolOptions{Root: root, Directory: t.TempDir(), Parallel: 501}},
		{"unsafe worker", PoolOptions{Root: root, Directory: t.TempDir(), Parallel: 1, WorkerPath: "relative"}},
		{"password line break", PoolOptions{Root: root, Directory: t.TempDir(), Parallel: 1, Password: "bad\nsecret"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := NewPool(tc.opts); err == nil {
				t.Fatal("accepted invalid options")
			}
		})
	}
	for _, parallel := range []int{1, 4, 5, 500} {
		p, err := NewPool(PoolOptions{Root: root, Directory: t.TempDir(), Parallel: parallel})
		if err != nil {
			t.Fatal(err)
		}
		if len(p.clients) != (parallel+3)/4 || len(p.available) != parallel {
			t.Fatalf("parallel %d: clients %d, slots %d", parallel, len(p.clients), len(p.available))
		}
		if err := p.Close(); err != nil {
			t.Fatal(err)
		}
	}
}

func TestPoolLocalPipes(t *testing.T) {
	root := t.TempDir()
	root, _ = filepath.EvalSymlinks(root)
	p, err := NewPool(PoolOptions{Root: root, Directory: t.TempDir(), Parallel: 5})
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	if err := p.Prepare(context.Background(), nil); err != nil {
		t.Fatal(err)
	}
	receipt, err := p.Upload(context.Background(), "running.cfg", "archive.cfg", func(_ context.Context, filename string) (transfer.Receipt, error) {
		if err := os.WriteFile(filepath.Join(root, filename), []byte("real local pipe"), 0600); err != nil {
			return transfer.Receipt{}, err
		}
		return transfer.Receipt{Path: filename, Verification: "device_reported"}, nil
	})
	if err != nil || !receipt.Receipt.Verified() || receipt.Receipt.Local.Path == "" {
		t.Fatalf("receipt %+v, err %v", receipt, err)
	}
	if len(p.available) != 5 {
		t.Fatalf("returned slots: %d", len(p.available))
	}
	if err := p.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := p.Upload(context.Background(), "running.cfg", "again.cfg", nil); err == nil {
		t.Fatal("upload after close")
	}
}

func TestPoolCloseCancelsActiveUpload(t *testing.T) {
	root := t.TempDir()
	root, _ = filepath.EvalSymlinks(root)
	p, err := NewPool(PoolOptions{Root: root, Directory: t.TempDir(), Parallel: 1})
	if err != nil {
		t.Fatal(err)
	}
	if err := p.Prepare(context.Background(), nil); err != nil {
		t.Fatal(err)
	}
	entered := make(chan struct{})
	finished := make(chan error, 1)
	go func() {
		_, err := p.Upload(context.Background(), "running.cfg", "archive.cfg", func(ctx context.Context, _ string) (transfer.Receipt, error) {
			close(entered)
			<-ctx.Done()
			return transfer.Receipt{}, ctx.Err()
		})
		finished <- err
	}()
	<-entered
	if err := p.Close(); err != nil {
		t.Fatal(err)
	}
	if err := <-finished; err == nil {
		t.Fatal("upload did not cancel")
	}
}

func TestPoolLocalDailyDirectoryReuse(t *testing.T) {
	root := t.TempDir()
	root, _ = filepath.EvalSymlinks(root)
	base := "2026-10-26_12-34-56"
	report := filepath.Join(t.TempDir(), base)
	// Multiple runs on the same day share one human-readable directory.
	day := time.Now().In(time.FixedZone("UTC+8", 8*3600)).Format("2006-01-02")
	for _, want := range []string{day, day, day} {
		p, err := NewPool(PoolOptions{Root: root, Directory: report, Parallel: 5})
		if err != nil {
			t.Fatal(err)
		}
		if err := p.Prepare(context.Background(), nil); err != nil {
			t.Fatal(err)
		}
		for _, client := range p.clients {
			if client.batch != want {
				t.Fatalf("batch %q, want %q", client.batch, want)
			}
		}
		if _, err := os.Stat(filepath.Join(root, "archive", want)); err != nil {
			t.Fatal(err)
		}
		if err := p.Close(); err != nil {
			t.Fatal(err)
		}
	}
	for _, want := range []string{day, day} {
		p, err := NewPool(PoolOptions{Root: root, Directory: filepath.Join(t.TempDir(), base+"_09"), Parallel: 1})
		if err != nil {
			t.Fatal(err)
		}
		if err := p.Prepare(context.Background(), nil); err != nil {
			t.Fatal(err)
		}
		if p.clients[0].batch != want {
			t.Fatalf("batch %q, want %q", p.clients[0].batch, want)
		}
		if err := p.Close(); err != nil {
			t.Fatal(err)
		}
	}

}

func TestPoolCloseCancelsAndJoinsPrepare(t *testing.T) {
	root := t.TempDir()
	root, _ = filepath.EvalSymlinks(root)
	p, err := NewPool(PoolOptions{Root: root, Directory: t.TempDir(), Parallel: 1})
	if err != nil {
		t.Fatal(err)
	}
	entered := make(chan struct{})
	p.clients[0].launch = func(ctx context.Context) (Channel, error) {
		client, server := net.Pipe()
		done := make(chan struct{})
		go func() {
			defer close(done)
			defer server.Close()
			buf := make([]byte, 4096)
			server.Read(buf)
			close(entered)
			<-ctx.Done()
		}()
		return Channel{Input: client, Output: client, Close: func() error { client.Close(); <-done; return nil }}, nil
	}
	prepared := make(chan error, 1)
	go func() { prepared <- p.Prepare(context.Background(), nil) }()
	<-entered
	closed := make(chan error, 1)
	go func() { closed <- p.Close() }()
	select {
	case err := <-closed:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("Close blocked behind Prepare")
	}
	select {
	case err := <-prepared:
		if err == nil {
			t.Fatal("Prepare succeeded after Close")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("Prepare not joined")
	}
}

func TestRemotePoolCloseCancelsAndJoinsPrepare(t *testing.T) {
	p, err := NewPool(PoolOptions{Root: "ssh://root@192.0.2.10/srv/tftp", Directory: t.TempDir(), Parallel: 1})
	if err != nil {
		t.Fatal(err)
	}
	p.masters[0].cmd = &exec.Cmd{Process: &os.Process{Pid: 1}}
	p.masters[0].reap = func(int, chan error) error { return nil }
	entered := make(chan struct{})
	p.clients[0].launch = func(ctx context.Context) (Channel, error) {
		client, server := net.Pipe()
		done := make(chan struct{})
		go func() {
			defer close(done)
			defer server.Close()
			request, readErr := readRequest(bufio.NewReader(server))
			if readErr != nil || request.Action != "probe" {
				return
			}
			close(entered)
			<-ctx.Done()
		}()
		return Channel{Input: client, Output: client, Close: func() error {
			_ = client.Close()
			<-done
			return nil
		}}, nil
	}
	prepared := make(chan error, 1)
	go func() { prepared <- p.Prepare(context.Background(), nil) }()
	select {
	case <-entered:
	case <-time.After(time.Second):
		_ = p.Close()
		t.Fatal("remote preflight did not enter the protocol probe")
	}
	closed := make(chan error, 1)
	go func() { closed <- p.Close() }()
	select {
	case err := <-closed:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("Close blocked behind remote Prepare")
	}
	select {
	case err := <-prepared:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("Prepare after Close = %v, want cancellation", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("remote Prepare was not joined")
	}
}

func TestPoolOptionDiagnosticsRetainExecutionPassword(t *testing.T) {
	o := PoolOptions{Root: "ssh://archive@example.test/var/tftp", Directory: t.TempDir(), Parallel: 1, Password: "private password"}
	_ = o.String()
	_, err := o.MarshalJSON()
	if err != nil {
		t.Fatal(err)
	}
	p, err := NewPool(o)
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	if len(p.masters) != 1 || p.masters[0].password != o.Password || p.masters[0].endpoint.Path != "/var/tftp" {
		t.Fatal("option diagnostics changed execution")
	}
}

func TestRemotePoolSharesOneBatch(t *testing.T) {
	p, err := NewPool(PoolOptions{Root: "ssh://root@192.0.2.10/srv/tftp", Directory: filepath.Join(t.TempDir(), "2026-11-04_14-34-44"), Parallel: 50})
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	want := p.clients[0].batch
	for _, c := range p.clients {
		if c.batch != want {
			t.Fatal("one batch fragmented across SSH clients")
		}
	}
}

func TestRemotePoolPreparesClientsWithBoundedConcurrency(t *testing.T) {
	p, err := NewPool(PoolOptions{Root: "ssh://root@192.0.2.10/srv/tftp", Directory: t.TempDir(), Parallel: 50})
	if err != nil {
		t.Fatal(err)
	}
	for _, master := range p.masters {
		master.cmd = &exec.Cmd{Process: &os.Process{Pid: 1}}
		master.reap = func(int, chan error) error { return nil }
	}

	var active, peak atomic.Int32
	started := make(chan struct{}, len(p.clients))
	release := make(chan struct{}, len(p.clients))
	for _, client := range p.clients {
		var preparing atomic.Bool
		client.launch = func(ctx context.Context) (Channel, error) {
			input, output := net.Pipe()
			done := make(chan struct{})
			go func() {
				defer close(done)
				defer output.Close()
				request, readErr := readRequest(bufio.NewReader(output))
				if readErr != nil {
					return
				}
				if request.Action == "probe" && !preparing.Swap(true) {
					current := active.Add(1)
					for previous := peak.Load(); current > previous && !peak.CompareAndSwap(previous, current); previous = peak.Load() {
					}
					started <- struct{}{}
					select {
					case <-release:
					case <-ctx.Done():
						return
					}
				}
				response := frame{OK: true, Phase: "ready", Version: Version}
				if request.Action == "probe" {
					response.Version = Version
					response.Capabilities = slices.Clone(capabilities)
				}
				encoded, _ := json.Marshal(response)
				if _, writeErr := output.Write(append(encoded, '\n')); writeErr == nil && request.Action == "preflight" && preparing.Swap(false) {
					active.Add(-1)
				}
			}()
			return Channel{Input: input, Output: input, Close: func() error {
				_ = input.Close()
				<-done
				return nil
			}}, nil
		}
	}

	prepared := make(chan error, 1)
	progressEvents := make(chan PrepareProgress, len(p.clients)*4)
	go func() {
		prepared <- p.Prepare(context.Background(), func(event PrepareProgress) {
			progressEvents <- event
		})
	}()
	for i := range min(4, len(p.clients)) {
		select {
		case <-started:
		case <-time.After(time.Second):
			for range len(p.clients) {
				release <- struct{}{}
			}
			_ = p.Close()
			t.Fatalf("only %d archive clients started before a probe completed", i)
		}
	}
	select {
	case <-started:
		for range len(p.clients) {
			release <- struct{}{}
		}
		_ = p.Close()
		t.Fatal("archive pool exceeded four concurrent preflights")
	case <-time.After(50 * time.Millisecond):
	}
	for range len(p.clients) {
		release <- struct{}{}
	}
	select {
	case err = <-prepared:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		_ = p.Close()
		t.Fatal("archive preflight did not finish")
	}
	if got := peak.Load(); got != 4 {
		t.Fatalf("peak in-flight archive preflights = %d, want 4", got)
	}
	var last PrepareProgress
	previousCompleted := 0
	for len(progressEvents) > 0 {
		current := <-progressEvents
		if current.Active < 0 || current.Active > 4 {
			t.Fatalf("reported active preflights = %d, want 0..4", current.Active)
		}
		if current.Completed < previousCompleted {
			t.Fatalf("completed count moved backwards: %d -> %d", previousCompleted, current.Completed)
		}
		previousCompleted = current.Completed
		last = current
	}
	if last.Completed != len(p.clients) || last.Total != len(p.clients) || last.Active != 0 || last.Workers != 4 || last.Stage != PrepareStageReady {
		t.Fatalf("final preflight progress = %+v", last)
	}
	var reused []PrepareProgress
	if err := p.Prepare(context.Background(), func(event PrepareProgress) { reused = append(reused, event) }); err != nil {
		t.Fatal(err)
	}
	if len(reused) != 1 || reused[0].Completed != len(p.clients) || reused[0].Total != len(p.clients) || reused[0].Workers != 4 || reused[0].Stage != PrepareStageReady {
		t.Fatalf("already-prepared progress = %+v", reused)
	}
	if err := p.Close(); err != nil {
		t.Fatal(err)
	}
}

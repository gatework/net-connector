package archive

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/creack/pty"

	"github.com/gatework/net-connector/transfer"
)

func TestInstalledWorkerCLI(t *testing.T) {
	worker := os.Getenv("NC_TEST_ARCHIVE_WORKER")
	if worker == "" {
		t.Skip("set NC_TEST_ARCHIVE_WORKER to built worker")
	}
	for _, tc := range []struct {
		name string
		args []string
		code int
		want string
	}{
		{"help", []string{"--help"}, 0, "用法：tftp-archive"},
		{"short help", []string{"-h"}, 0, "用法：tftp-archive"},
		{"version", []string{"--version"}, 0, "tftp-archive 协议版本 2"},
		{"unknown", []string{"--private-value"}, 2, "参数无效"},
		{"extra", []string{"--help", "private-value"}, 2, "参数无效"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, worker, tc.args...)
			var stdout, stderr strings.Builder
			cmd.Stdout, cmd.Stderr = &stdout, &stderr
			err := cmd.Run()
			code := 0
			if err != nil {
				var exit *exec.ExitError
				if !errors.As(err, &exit) {
					t.Fatal(err)
				}
				code = exit.ExitCode()
			}
			if code != tc.code {
				t.Fatalf("exit=%d stdout=%q stderr=%q", code, stdout.String(), stderr.String())
			}
			text := stdout.String()
			if tc.code != 0 {
				text = stderr.String()
				if stdout.Len() != 0 {
					t.Fatal("invalid arguments wrote protocol stdout")
				}
			} else if stderr.Len() != 0 {
				t.Fatalf("unexpected stderr %q", stderr.String())
			}
			if !strings.Contains(text, tc.want) || strings.Contains(text, "private-value") {
				t.Fatalf("output %q", text)
			}
		})
	}
	t.Run("interactive no args", func(t *testing.T) {
		master, terminal, err := pty.Open()
		if err != nil {
			t.Fatal(err)
		}
		defer master.Close()
		defer terminal.Close()
		ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, worker)
		cmd.Stdin = terminal
		output, err := cmd.CombinedOutput()
		if err != nil || !strings.Contains(string(output), "用法：tftp-archive") {
			t.Fatalf("interactive output=%q error=%v", output, err)
		}
	})
}

func TestInstalledWorkerPipes(t *testing.T) {
	worker := os.Getenv("NC_TEST_ARCHIVE_WORKER")
	if worker == "" {
		t.Skip("set NC_TEST_ARCHIVE_WORKER to built worker")
	}
	root := t.TempDir()
	root, _ = filepath.EvalSymlinks(root)
	client, e := NewClient(ClientOptions{Root: root, Directory: t.TempDir(), Launcher: CommandLauncher(worker)})
	if e != nil {
		t.Fatal(e)
	}
	if e = client.Prepare(context.Background()); e != nil {
		t.Fatal(e)
	}
	receipt, e := client.Upload(context.Background(), "running.txt", "device.txt", func(_ context.Context, name string) (transfer.Receipt, error) {
		if e := os.WriteFile(filepath.Join(root, name), []byte("process config"), 0600); e != nil {
			return transfer.Receipt{}, e
		}
		return transfer.Receipt{Path: name, Verification: "device_reported"}, nil
	})
	if e != nil || !receipt.Receipt.Verified() {
		t.Fatal(receipt, e)
	}
}

func TestCommandLauncherCloseKillsDescendantsAfterLeaderExit(t *testing.T) {
	pidFile := filepath.Join(t.TempDir(), "child.pid")
	ch, err := CommandLauncher("/bin/sh", "-c", "sleep 30 & echo $! > '"+pidFile+"'; exit 0")(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	var pid int
	for deadline := time.Now().Add(time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		b, _ := os.ReadFile(pidFile)
		if _, _ = fmt.Sscanf(string(b), "%d", &pid); pid > 0 {
			break
		}
	}
	if pid == 0 {
		t.Fatal("descendant pid unavailable")
	}
	defer syscall.Kill(pid, syscall.SIGKILL)
	if err := ch.Close(); err != nil {
		t.Fatal(err)
	}
	for deadline := time.Now().Add(time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		if errors.Is(syscall.Kill(pid, 0), syscall.ESRCH) {
			return
		}
	}
	t.Fatal("descendant survived Close")
}

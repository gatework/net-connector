package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/gatework/net-connector/internal/workflow"

	"github.com/gatework/net-connector/netdisco"
)

func TestChineseHelpIsOffline(t *testing.T) {
	for _, command := range [][]string{{"backup", "run"}, {"backup", "tftp"}, {"inventory", "list"}, {"topology", "apply"}, {"config", "init"}} {
		var out, errout bytes.Buffer
		args := append(append([]string{}, command...), "--help")
		r := Runtime{Args: args, Environment: map[string]string{"NC_CONFIG": "/unavailable"}, Input: panicReader{}, Output: &out, Error: &errout}
		if code := r.Run(t.Context()); code != 0 {
			t.Fatalf("%v: exit %d", command, code)
		}
		text := out.String()
		if !strings.ContainsAny(text, "用法示例选项") || strings.Contains(text, "Show ") || strings.Contains(text, "Usage:") {
			t.Fatalf("help is not Chinese: %s", text)
		}
	}
}

func TestCacheNamespaceFailureExplainsRequiredSetting(t *testing.T) {
	var output bytes.Buffer
	r := Runtime{Error: &output}
	if code := r.fail("netman", &netdisco.InventoryError{Code: "cache_namespace_required"}); code != 2 {
		t.Fatalf("exit code %d", code)
	}
	if got := output.String(); !strings.Contains(got, "ND_CACHE_NAMESPACE") || !strings.Contains(got, "非敏感账户标识") {
		t.Fatalf("unexpected message: %s", got)
	}
}

func TestBackupProgressDoesNotClaimUncommittedSource(t *testing.T) {
	out := workflow.OutcomeEvent{Status: "failed", TextWarningBytes: 1}
	if got := backupProgress(out); strings.Contains(got, "原文已保留") || !strings.Contains(got, "原文保存未确认") {
		t.Fatal(got)
	}
}

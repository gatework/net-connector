package cli

import (
	"context"
	"fmt"
	"io"

	"github.com/gatework/net-connector/internal/display"
	"github.com/gatework/net-connector/internal/textdiff"
	"github.com/gatework/net-connector/storage"
)

// diffBatches compares one device's saved configuration between two batches.
// Both sides are read through the verified export path, so a tampered or
// mismatched batch is refused instead of diffed. Exit codes follow diff(1):
// 0 identical, 1 different, 2 error.
func (r Runtime) diffBatches(ctx context.Context, host, from, to string, jsonOutput bool) int {
	if from == "" || to == "" {
		return r.fail("netman", newUsageError("必须通过 --from 与 --to 指定两个批次目录"))
	}
	before, beforeArtifact, err := storage.ReadBatchSaved(ctx, from, host)
	if err != nil {
		return r.fail("netman", err)
	}
	after, afterArtifact, err := storage.ReadBatchSaved(ctx, to, host)
	if err != nil {
		return r.fail("netman", err)
	}
	ops := textdiff.Diff(textdiff.Lines(string(before)), textdiff.Lines(string(after)))
	added, removed := textdiff.Stats(ops)
	unified := textdiff.Unified(beforeArtifact.Path, afterArtifact.Path, ops, 3)
	code := 0
	if unified != "" {
		code = 1
	}
	if jsonOutput {
		if e := writeReportOutput(r.Output, map[string]any{
			"host": beforeArtifact.Host, "from": beforeArtifact.Path, "to": afterArtifact.Path,
			"from_sha256": beforeArtifact.SHA256, "to_sha256": afterArtifact.SHA256,
			"changed": code == 1, "added": added, "removed": removed, "diff": unified,
		}); e != nil {
			return r.fail("netman", e)
		}
		return code
	}
	text := unified
	if text == "" {
		text = fmt.Sprintf("配置一致：%s\n", display.Text(beforeArtifact.Host))
	} else {
		text += fmt.Sprintf("新增 %d 行；删除 %d 行\n", added, removed)
	}
	if _, e := io.WriteString(r.Output, text); e != nil {
		return r.fail("netman", e)
	}
	return code
}

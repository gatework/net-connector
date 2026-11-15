package cli

import (
	"context"
	"fmt"
	"io"

	"github.com/gatework/net-connector/internal/display"

	"github.com/gatework/net-connector/storage"
)

// exportBatch is independent of configuration, inventory, and device factories.
func (r Runtime) exportBatch(ctx context.Context, host, batch, output string, jsonOutput bool) int {
	if output != "" {
		artifact, receipt, err := storage.ExportBatchSaved(ctx, batch, host, output)
		if err != nil {
			if ctx.Err() != nil {
				return 130
			}
			return r.fail("netman", err)
		}
		code := 0
		if jsonOutput {
			code = r.print(map[string]any{"host": artifact.Host, "batch": artifact.Batch, "source": artifact.Path, "output": receipt.Path, "bytes": artifact.Bytes, "sha256": artifact.SHA256, "source_status": artifact.Status, "file": receipt})
		} else {
			text := fmt.Sprintf("已导出：%s\n设备：%s；字节：%d；来源状态：%s\nSHA-256：%s\n", display.Text(receipt.Path), display.Text(artifact.Host), artifact.Bytes, display.Status(artifact.Status), artifact.SHA256)
			n, e := io.WriteString(r.Output, text)
			if e == nil && n != len(text) {
				e = io.ErrShortWrite
			}
			if e != nil {
				code = r.fail("netman", e)
			}
		}
		if ctx.Err() != nil {
			return 130
		}
		return code
	}
	body, _, err := storage.ReadBatchSaved(ctx, batch, host)
	if err != nil {
		if ctx.Err() != nil {
			return 130
		}
		return r.fail("netman", err)
	}
	if err = ctx.Err(); err != nil {
		return r.fail("netman", err)
	}
	n, err := r.Output.Write(body)
	if err == nil && n != len(body) {
		err = io.ErrShortWrite
	}
	if err != nil {
		if ctx.Err() != nil {
			return 130
		}
		_, _ = fmt.Fprintln(r.Error, "netman：导出输出失败")
		return 2
	}
	if ctx.Err() != nil {
		return 130
	}
	return 0
}

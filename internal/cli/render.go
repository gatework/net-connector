package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"golang.org/x/term"

	"github.com/gatework/net-connector/fleet"
	"github.com/gatework/net-connector/internal/batchreport"
	"github.com/gatework/net-connector/internal/display"
	"github.com/gatework/net-connector/internal/workflow"
)

func operationLabel(o options) string {
	if o.action == "inventory" {
		return "设备清单"
	}
	switch o.mode {
	case "deploy":
		return "脚本下发"
	case "exec":
		return "只读命令采集"
	case "facts":
		return "设备事实采集"
	case "remote":
		return "远程导出备份"
	case "tftp":
		return "TFTP 备份"
	case "topology":
		return "邻居接口描述"
	default:
		return "配置备份"
	}
}

func writeReportOutput(w io.Writer, v any) error {
	e := json.NewEncoder(w)
	e.SetIndent("", "  ")
	return e.Encode(v)
}

// renderResult prints the command result. JSON output is the report itself,
// identical to report.json, so scripts read one format for every operation.
func (r Runtime) renderResult(result workflow.Result, o options, interrupted bool) error {
	if result.Inventory != nil {
		if o.json {
			rows := inventoryRows(result.Inventory)
			selected := 0
			for _, row := range rows {
				if row.Status == "ready" {
					selected++
				}
			}
			return writeReportOutput(r.Output, map[string]any{"total": len(rows), "selected": selected, "devices": rows})
		}
		return r.inventoryTable(result.Inventory)
	}
	report := result.Report
	if report == nil {
		return nil
	}
	if o.json {
		return writeReportOutput(r.Output, report)
	}
	var b strings.Builder
	if result.Planned {
		r.writePlan(&b, report)
	} else {
		r.writeReport(&b, report, result.ArchiveDirectories, interrupted)
	}
	text := strings.Map(func(c rune) rune {
		if c < ' ' && c != '\n' && c != '\t' || c == 127 {
			return ' '
		}
		return c
	}, b.String())
	_, err := io.WriteString(r.Output, text)
	return err
}

func (r Runtime) width() int {
	if f, ok := r.Output.(*os.File); ok {
		if n, _, err := term.GetSize(int(f.Fd())); err == nil {
			return n
		}
	}
	return 120
}

func (r Runtime) writePlan(b *strings.Builder, report *batchreport.Report) {
	rows := [][5]string{}
	for _, d := range report.Devices {
		if d.Status == "filtered" {
			continue
		}
		rows = append(rows, [5]string{d.Host, d.Name, d.Platform, targetText(d.Target), display.Status(string(d.Status))})
	}
	_ = display.Table(b, rows, r.width())
	planned := report.Counts[batchreport.StatusNotStarted]
	fmt.Fprintf(b, "清单 %d 台；计划执行 %d 台", report.Total, planned)
	for _, status := range slices.Sorted(maps.Keys(report.Counts)) {
		if n := report.Counts[status]; status != batchreport.StatusNotStarted && status != batchreport.StatusFiltered && n > 0 {
			fmt.Fprintf(b, "；%s %d 台", display.Status(string(status)), n)
		}
	}
	b.WriteString("\n")
}

func targetText(t *batchreport.Target) string {
	if t == nil {
		return ""
	}
	parts := []string{}
	if t.Script != "" {
		parts = append(parts, fmt.Sprintf("%s（%d 条）", t.Script, t.Commands))
	}
	if t.File != "" {
		parts = append(parts, t.File)
	}
	if t.Server != "" {
		parts = append(parts, "→ "+t.Server)
	}
	return strings.Join(parts, " ")
}

// writeReport renders a batch report: warnings, results, the devices that
// need attention and where the files are.
func (r Runtime) writeReport(b *strings.Builder, report *batchreport.Report, archives []string, interrupted bool) {
	failed := report.Counts[batchreport.StatusFailed]
	partial := report.Counts[batchreport.StatusPartial]
	r.writeWarnings(b, report, interrupted)
	b.WriteString(display.Section(r.Output, "执行结果"))
	state := "完成"
	if !report.Success {
		state = "未完成"
	}
	skipped := report.Total - report.Counts[batchreport.StatusSucceeded] - partial - failed - report.Counts[batchreport.StatusInterrupted] - report.Counts[batchreport.StatusNotStarted] - report.Counts[batchreport.StatusStopped]
	fmt.Fprintf(b, "批次%s：成功 %d；部分完成 %d；失败 %d；跳过 %d\n", state, report.Counts[batchreport.StatusSucceeded], partial, failed, skipped)
	if attention := attentionRows(report); len(attention) > 0 {
		_ = display.Table(b, attention, r.width())
	}
	b.WriteString(display.Section(r.Output, "文件与报告"))
	for _, path := range archives {
		fmt.Fprintf(b, "服务器归档目录：%s\n", display.Text(path))
	}
	fmt.Fprintf(b, "批次目录：%s\nJSON 报告：%s\n", display.Text(report.Directory), display.Text(filepath.Join(report.Directory, "report.json")))
	if report.Operation == "topology" {
		if _, err := os.Stat(filepath.Join(report.Directory, "scripts")); err == nil {
			fmt.Fprintf(b, "命令文件：%s\n", display.Text(filepath.Join(report.Directory, "scripts")))
		}
	}
	if report.Operation == "deploy" {
		for _, entry := range [][2]string{{"变更前快照", "before"}, {"配置差异", "diff"}} {
			if _, err := os.Stat(filepath.Join(report.Directory, entry[1])); err == nil {
				fmt.Fprintf(b, "%s：%s\n", entry[0], display.Text(filepath.Join(report.Directory, entry[1])))
			}
		}
	}
}

// writeWarnings renders the failure, stop, interruption, verification,
// encoding and report warnings, if any.
func (r Runtime) writeWarnings(b *strings.Builder, report *batchreport.Report, interrupted bool) {
	failed := report.Counts[batchreport.StatusFailed]
	partial := report.Counts[batchreport.StatusPartial]
	textWarnings, unverified, unchanged := 0, 0, 0
	for _, d := range report.Devices {
		if c := d.Artifacts.Change; c != nil && c.Compared && !c.Changed && d.Status == batchreport.StatusSucceeded {
			unchanged++
		}
		if d.Artifacts.Backup != nil && d.Artifacts.Backup.TextWarning != nil && d.Artifacts.Backup.TextWarning.Count > 0 {
			textWarnings++
		}
		if d.Artifacts.Transfer != nil && !d.Verified {
			unverified++
		}
	}
	if failed == 0 && partial == 0 && unverified == 0 && textWarnings == 0 && unchanged == 0 && report.ReportError == "" && !report.Stopped && !interrupted {
		return
	}
	b.WriteString(display.Section(r.Output, "异常与警告"))
	if failed > 0 || partial > 0 {
		fmt.Fprintf(b, "任务异常：失败 %d 台；部分完成 %d 台；逐台诊断见下表与报告。\n", failed, partial)
	}
	if report.Stopped {
		b.WriteString("失败数量达到上限，其余设备未启动。\n")
	}
	if interrupted {
		b.WriteString("批次已中断；未开始的设备未连接。\n")
	}
	if unverified > 0 {
		fmt.Fprintf(b, "服务器文件待核验：%d 台设备仅报告上传完成。\n", unverified)
	}
	if unchanged > 0 {
		fmt.Fprintf(b, "配置无变化：%d 台设备接受了全部命令，但变更前后的配置一致；请确认脚本是否生效。\n", unchanged)
	}
	if textWarnings > 0 {
		fmt.Fprintf(b, "编码警告：%d 台；请核对设备配置中的异常字符。\n", textWarnings)
	}
	if report.ReportError != "" {
		fmt.Fprintf(b, "报告写入异常：%s\n", display.Error(report.ReportError))
	}
	if report.Operation == "deploy" && (failed > 0 || partial > 0) {
		b.WriteString("注意：失败或部分完成的设备可能已部分生效，请按报告逐台核对，不要直接重跑整份脚本。\n")
	}
}

// attentionRows lists the devices an operator should look at: every
// partial, failed or interrupted one, and topology devices that changed.
func attentionRows(report *batchreport.Report) [][5]string {
	attention := [][5]string{}
	for _, d := range report.Devices {
		if d.Status != batchreport.StatusSucceeded && d.Status != batchreport.StatusPartial && d.Status != batchreport.StatusFailed && d.Status != batchreport.StatusInterrupted {
			continue
		}
		if d.Status == batchreport.StatusSucceeded && (report.Operation != "topology" || d.Outcome == "unchanged" || d.Outcome == "discovered") {
			continue
		}
		attention = append(attention, [5]string{d.Host, d.Name, d.Platform, display.Status(firstNonEmpty(string(d.Outcome), string(d.Status))), deviceNote(d)})
	}
	return attention
}

// deviceNote explains a device result: the failed stage and its diagnostic,
// or how far a script got.
func deviceNote(d batchreport.Device) string {
	parts := []string{}
	if d.FailedStage != "" {
		parts = append(parts, "阶段 "+d.FailedStage)
	}
	if d.Diagnostic != nil {
		parts = append(parts, display.Error(d.Diagnostic.Code))
	}
	if c := d.Artifacts.Change; c != nil && c.Compared {
		parts = append(parts, fmt.Sprintf("配置 +%d/-%d 行", c.Added, c.Removed))
	}
	if f := d.Artifacts.Facts; f != nil && len(f.Mismatches) > 0 {
		parts = append(parts, "不一致字段："+strings.Join(f.Mismatches, "、"))
	}
	if s := d.Artifacts.Script; s != nil {
		parts = append(parts, fmt.Sprintf("已接受 %d/%d 条", s.Accepted, s.Commands))
		if s.FailedLine > 0 {
			parts = append(parts, fmt.Sprintf("第 %d 行", s.FailedLine))
		}
	}
	return strings.Join(parts, "；")
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

type inventoryRow struct {
	Host     string `json:"host"`
	Name     string `json:"name,omitempty"`
	Platform string `json:"platform,omitempty"`
	Model    string `json:"model,omitempty"`
	Status   string `json:"status"`
}

func inventoryRows(entries []fleet.PlanEntry) []inventoryRow {
	rows := make([]inventoryRow, 0, len(entries))
	for _, e := range entries {
		d := e.Device
		host, vendor := d.Host, d.Platform
		if host == "" {
			host = d.SourceIP
		}
		if vendor == "" {
			vendor = d.SourceVendor
		}
		rows = append(rows, inventoryRow{Host: host, Name: d.Name, Platform: vendor, Model: d.Model, Status: e.Status})
	}
	return rows
}

func (r Runtime) inventoryTable(entries []fleet.PlanEntry) error {
	rows := [][5]string{}
	normal := [][5]string{}
	selected := 0
	for _, row := range inventoryRows(entries) {
		if row.Status == "filtered" {
			continue
		}
		cells := [5]string{row.Host, row.Name, row.Platform, row.Model, display.Status(row.Status)}
		if row.Status == "ready" {
			selected++
		}
		if row.Status != "ready" && row.Status != "sample_limit" {
			rows = append(rows, cells)
		} else {
			normal = append(normal, cells)
		}
	}
	rows = append(rows, normal...)
	if err := display.Table(r.Output, rows, r.width()); err != nil {
		return err
	}
	_, err := fmt.Fprintf(r.Output, "清单 %d 台；选中 %d 台\n", len(rows), selected)
	return err
}

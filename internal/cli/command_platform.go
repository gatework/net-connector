package cli

import (
	"encoding/json"
	"io"
	"strings"

	"github.com/rivo/uniseg"
	"github.com/spf13/cobra"

	"github.com/gatework/net-connector/internal/workflow"
	"github.com/gatework/net-connector/vendors"
)

func addPlatformCommands(root *cobra.Command) {
	group := commandGroup("platform", "查看内建平台及其声明的能力，不读取配置或凭据")
	var asJSON bool
	list := &cobra.Command{
		Use: "list", Short: "列出内建平台键与能力矩阵",
		Long:    "列出内建平台键与源码声明的能力；声明不代表实机兼容性，不读取配置或凭据。",
		Example: "  netman platform list --json", Args: noArguments,
		RunE: func(c *cobra.Command, _ []string) error {
			rows, err := workflow.PlatformCapabilities(vendors.NewBuiltinRegistry())
			if err != nil {
				return err
			}
			return renderPlatforms(c.OutOrStdout(), rows, asJSON)
		},
	}
	list.Flags().BoolVar(&asJSON, "json", false, "输出 JSON")
	group.AddCommand(list)
	root.AddCommand(group)
}

func renderPlatforms(w io.Writer, rows []workflow.Capabilities, asJSON bool) error {
	if asJSON {
		enc := json.NewEncoder(w)
		enc.SetIndent("", "  ")
		return enc.Encode(map[string]any{"platforms": rows})
	}
	mark := func(supported bool) string {
		if supported {
			return "是"
		}
		return "-"
	}
	table := [][]string{{"平台", "配置采集", "保存", "提交", "只读命令", "事实采集", "邻居发现", "描述读取", "接口映射", "描述写入", "TFTP", "远程导出"}}
	for _, r := range rows {
		table = append(table, []string{r.Platform, mark(r.ConfigCollection), mark(r.Save), mark(r.Commit), mark(r.ReadOnlyCommands), mark(r.Facts), mark(r.NeighborDiscovery),
			mark(r.DescriptionRead), mark(r.InterfaceIdentity), mark(r.DescriptionWrite), mark(r.TFTP), mark(r.RemoteBackup)})
	}
	// Pad by display width: East Asian wide characters occupy two columns.
	widths := make([]int, len(table[0]))
	for _, row := range table {
		for i, cell := range row {
			widths[i] = max(widths[i], uniseg.StringWidth(cell))
		}
	}
	var b strings.Builder
	for _, row := range table {
		for i, cell := range row {
			b.WriteString(cell)
			if i < len(row)-1 {
				b.WriteString(strings.Repeat(" ", widths[i]-uniseg.StringWidth(cell)+2))
			}
		}
		b.WriteString("\n")
	}
	_, err := io.WriteString(w, b.String())
	return err
}

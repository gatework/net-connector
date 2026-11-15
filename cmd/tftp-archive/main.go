// Command tftp-archive runs on the TFTP server and is invoked over SSH by
// `netman backup tftp`. It checks protocol capabilities and directory
// permissions before a device uploads, verifies that the uploaded file is
// fresh and stable, hashes and archives it by date, and returns it to the
// client.
package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"golang.org/x/sys/unix"
	"golang.org/x/term"

	"github.com/gatework/net-connector/archive"
	"github.com/gatework/net-connector/internal/buildinfo"
)

func main() {
	os.Exit(run())
}

func run() int {
	args := os.Args[1:]
	if len(args) == 1 {
		switch args[0] {
		case "--help", "-h":
			return printHelp()
		case "--version":
			return writeText(os.Stdout, fmt.Sprintf("tftp-archive 协议版本 %d；%s\n", archive.Version, buildinfo.Identity))
		}
	}
	if len(args) != 0 {
		_ = writeText(os.Stderr, "tftp-archive：参数无效；请使用 tftp-archive --help 查看用法\n")
		return 2
	}
	if term.IsTerminal(int(os.Stdin.Fd())) {
		return printHelp()
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	input, err := pollableStandardFile(os.Stdin)
	if err != nil {
		return 1
	}
	defer input.Close()
	output, err := pollableStandardFile(os.Stdout)
	if err != nil {
		return 1
	}
	defer output.Close()
	if archive.Serve(ctx, input, output) != nil {
		return 1
	}
	return 0
}

func printHelp() int {
	return writeText(os.Stdout, "TFTP 文件归档与核验服务\n\n用法：tftp-archive [选项]\n\n由 netman 通过 SSH 调用，核验设备上传文件、按日期归档并回传备份。\n不负责接收 TFTP 网络请求；请在 TFTP 服务器上另行运行 TFTP 服务。\n\n选项：\n  -h, --help  显示中文帮助，不启动协议服务\n  --version   显示程序身份与协议版本\n\n部署：\n  默认安装路径为 /usr/local/bin/tftp-archive。\n  无参数且标准输入为管道时，通过标准输入和标准输出交换归档协议消息。\n  直接在终端无参数运行时显示帮助；协议模式的标准输出仅包含协议数据。\n")
}

func writeText(w io.Writer, text string) int {
	n, err := io.WriteString(w, text)
	if err != nil || n != len(text) {
		return 1
	}
	return 0
}

func pollableStandardFile(file *os.File) (*os.File, error) {
	fd, err := unix.Dup(int(file.Fd()))
	if err != nil {
		return nil, err
	}
	unix.CloseOnExec(fd)
	if err = unix.SetNonblock(fd, true); err != nil {
		unix.Close(fd)
		return nil, err
	}
	return os.NewFile(uintptr(fd), "archive-protocol"), nil
}

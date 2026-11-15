// Command netman is the operator entry point for device automation: login,
// configuration collection and backup (TFTP and native remote), neighbor
// discovery and interface description repair, batch script deployment and
// read-only command collection.
package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"

	"github.com/gatework/net-connector/internal/cli"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	code := (cli.Runtime{Args: os.Args[1:], Input: os.Stdin, Output: os.Stdout, Error: os.Stderr, Program: os.Args[0]}).Run(ctx)
	stop()
	os.Exit(code)
}

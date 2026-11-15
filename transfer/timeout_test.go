package transfer_test

import (
	"bufio"
	"context"
	"errors"
	"io"
	"net"
	"testing"
	"time"

	"github.com/gatework/net-connector/transfer"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/vendors"
)

func TestUploadCommandTimeoutOverride(t *testing.T) {
	for _, vendor := range []string{"h3c", "huawei", "cisco_ios", "cisco_nxos", "fortinet", "centec", "hillstone", "palo_alto", "radware"} {
		c := tftpPolicyForTest(t, vendor).Command("192.0.2.1", transfer.TFTPOptions{Timeout: 35 * time.Second}, true)
		if c.Timeout == nil || *c.Timeout != 35*time.Second {
			t.Fatalf("%s override ignored", vendor)
		}
	}
}
func TestUploadTimeoutPreservesLibraryDefault(t *testing.T) {
	c := tftpPolicyForTest(t, "h3c").Command("192.0.2.1", transfer.TFTPOptions{Timeout: 180 * time.Second}, true)
	if *c.Timeout != 180*time.Second {
		t.Fatal(*c.Timeout)
	}
}
func TestSilentUploadIsBounded(t *testing.T) {
	d := transferDevice(t, "h3c", [][2]string{{"tftp 192.0.2.10 put startup.cfg output.cfg", ""}})
	start := time.Now()
	_, err := transfer.TFTP(t.Context(), vendors.NewBuiltinRegistry(), d, transfer.TFTPOptions{Server: "192.0.2.10", SourceFile: "startup.cfg", Path: "output.cfg", Timeout: 30 * time.Millisecond})
	var ce *connector.Error
	if !errors.As(err, &ce) || ce.Code != "command_timeout" {
		t.Fatal(err)
	}
	if time.Since(start) > time.Second {
		t.Fatal("upload exceeded deadline")
	}
}

func TestUploadTimeoutCoversSourceDiscoveryAndTransfer(t *testing.T) {
	started := make(chan time.Time, 1)
	done := make(chan struct{})
	d, err := connector.New(connector.StaticDriver{Grammar: connector.Terminal{
		Name: "h3c", LoginPrompt: testPattern(`sw#\s*$`), CommandPrompt: testPattern(`sw#\s*$`),
	}}, connector.ConnectionConfig{Host: "192.0.2.1", CommandTimeout: time.Second}, connector.WithTransportFactory(func(context.Context, connector.ConnectionConfig) (io.ReadWriteCloser, error) {
		client, peer := net.Pipe()
		go func() {
			defer close(done)
			defer peer.Close()
			_, _ = io.WriteString(peer, "sw#")
			reader := bufio.NewReader(peer)
			command, readErr := reader.ReadString('\n')
			if readErr != nil || command != "display startup\n" {
				return
			}
			time.Sleep(300 * time.Millisecond)
			_, _ = io.WriteString(peer, "Next main startup saved-configuration file: flash:/startup.cfg\r\nsw#")
			command, readErr = reader.ReadString('\n')
			if readErr != nil || command != "tftp 192.0.2.10 put flash:/startup.cfg backup.cfg\n" {
				return
			}
			started <- time.Now()
			_, _ = io.Copy(io.Discard, peer)
		}()
		return client, nil
	}))
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()

	_, err = transfer.TFTP(t.Context(), vendors.NewBuiltinRegistry(), d, transfer.TFTPOptions{Server: "192.0.2.10", Path: "backup.cfg", Timeout: 500 * time.Millisecond})
	if err == nil {
		t.Fatal("silent upload unexpectedly completed")
	}
	select {
	case began := <-started:
		if elapsed := time.Since(began); elapsed > 350*time.Millisecond {
			t.Fatalf("upload received a fresh timeout after source discovery: %s", elapsed)
		}
	case <-time.After(time.Second):
		t.Fatal("upload command did not start")
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("device worker did not stop")
	}
}

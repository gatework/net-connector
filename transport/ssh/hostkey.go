package ssh

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/skeema/knownhosts"
	xssh "golang.org/x/crypto/ssh"

	"github.com/gatework/netops/store/disk"
)

// Policy decides how unknown and changed host keys are handled.
type Policy string

// Host key policies.
const (
	// Strict accepts only keys already in known_hosts.
	Strict Policy = "strict"
	// AcceptNew records the key of a host seen for the first time and
	// rejects a changed key.
	AcceptNew Policy = "accept-new"
	// Replace also replaces a changed key. It needs an explicit
	// known_hosts file dedicated to the tool.
	Replace Policy = "replace"
)

func (p Policy) valid() bool { return p == Strict || p == AcceptNew || p == Replace }

type hostKeyError struct {
	reason string
	host   string
}

func (e *hostKeyError) Error() string { return "ssh: " + e.reason + " for " + e.host }

// trust verifies host keys against a known_hosts file, re-reading it on
// every handshake so concurrent tools and edits are honored.
type trust struct {
	path   string
	policy Policy
}

func (t *trust) db() (*knownhosts.HostKeyDB, error) {
	db, err := knownhosts.NewDB(t.path)
	if errors.Is(err, fs.ErrNotExist) {
		return knownhosts.NewDB(os.DevNull)
	}
	return db, err
}

// algorithms returns the host key algorithms of keys already known for
// addr, so a known host negotiates a key it can be verified with.
func (t *trust) algorithms(addr string) []string {
	db, err := t.db()
	if err != nil {
		return nil
	}
	return db.HostKeyAlgorithms(addr)
}

func (t *trust) callback(hostname string, remote net.Addr, key xssh.PublicKey) error {
	db, err := t.db()
	if err != nil {
		return fmt.Errorf("ssh: known_hosts: %w", err)
	}
	err = db.HostKeyCallback()(hostname, remote, key)
	switch {
	case err == nil:
		return nil
	case knownhosts.IsHostUnknown(err) && t.policy != Strict:
		return t.record(hostname, remote, key, false)
	case knownhosts.IsHostKeyChanged(err) && t.policy == Replace:
		return t.record(hostname, remote, key, true)
	case knownhosts.IsHostUnknown(err):
		return &hostKeyError{reason: "unknown_host_key", host: hostname}
	case knownhosts.IsHostKeyChanged(err):
		return &hostKeyError{reason: "changed_host_key", host: hostname}
	}
	return err
}

// record appends the key of hostname, first dropping its plain-text
// entries when replacing. Hashed entries cannot be matched and are kept.
func (t *trust) record(hostname string, remote net.Addr, key xssh.PublicKey, replace bool) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := disk.PrepareDir(filepath.Dir(t.path)); err != nil {
		return fmt.Errorf("ssh: known_hosts: %w", err)
	}
	lock, err := disk.Lock(ctx, t.path+".lock", 0)
	if err != nil {
		return fmt.Errorf("ssh: known_hosts: %w", err)
	}
	defer func() { _ = lock.Close() }()
	body, _, err := disk.ReadFile(ctx, t.path, 16<<20)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return fmt.Errorf("ssh: known_hosts: %w", err)
	}
	if replace {
		body = drop(body, knownhosts.Normalize(hostname))
	}
	var line bytes.Buffer
	if err := knownhosts.WriteKnownHost(&line, hostname, remote, key); err != nil {
		return fmt.Errorf("ssh: known_hosts: %w", err)
	}
	if len(body) > 0 && body[len(body)-1] != '\n' {
		body = append(body, '\n')
	}
	if _, err := disk.WriteFile(ctx, t.path, append(body, line.Bytes()...)); err != nil {
		return fmt.Errorf("ssh: known_hosts: %w", err)
	}
	return nil
}

// drop removes the plain-text lines that list host.
func drop(body []byte, host string) []byte {
	var out bytes.Buffer
	sc := bufio.NewScanner(bytes.NewReader(body))
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		line := sc.Text()
		fields := strings.Fields(line)
		if len(fields) >= 2 && !strings.HasPrefix(fields[0], "#") && !strings.HasPrefix(fields[0], "|") &&
			slices.Contains(strings.Split(fields[0], ","), host) {
			continue
		}
		out.WriteString(line)
		out.WriteByte('\n')
	}
	return out.Bytes()
}

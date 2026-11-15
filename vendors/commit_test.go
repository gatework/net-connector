package vendors

import (
	"context"
	"errors"
	"io"
	"testing"

	"github.com/gatework/net-connector/connector"
)

const (
	junosOperational = "admin@mx> "
	junosConfig      = "\r\n[edit]\r\nadmin@mx# "
	panosOperational = "admin@fw> "
	panosConfig      = "\r\n[edit]\r\nadmin@fw# "
)

func commitScript(t *testing.T, text string) connector.Script {
	t.Helper()
	script, err := connector.ParseScript(text, "change.txt")
	if err != nil {
		t.Fatal(err)
	}
	return script
}

func commit(t *testing.T, d *connector.Device, script connector.Script, o connector.CommitOptions) (result connector.Result, err error) {
	t.Helper()
	operationErr := d.WithOperation(t.Context(), func(ctx context.Context, op *connector.Operation) error {
		result, err = op.Commit(ctx, script, o)
		return err
	})
	return result, operationErr
}

func TestJuniperCommitSendsExactCandidateSequence(t *testing.T) {
	d, check := dialogue(t, "juniper", junosOperational, []exchange{
		{"configure exclusive\n", "warning: uncommitted changes will be discarded on exit\r\nEntering configuration mode\r\n" + junosConfig},
		{"set system ntp server 192.0.2.5\n", junosConfig},
		{"commit check\n", "configuration check succeeds\r\n" + junosConfig},
		{"commit\n", "commit complete\r\n" + junosConfig},
		{"exit\n", "Exiting configuration mode\r\n\r\n" + junosOperational},
	})
	result, err := commit(t, d, commitScript(t, "set system ntp server 192.0.2.5\n"), connector.CommitOptions{})
	if err != nil {
		t.Fatalf("confirmed commit rejected: %v", err)
	}
	if steps := result.Steps(); len(steps) != 5 || steps[1].Command().Line != 1 || steps[0].Command().Line != 0 {
		t.Fatalf("steps = %d", len(steps))
	}
	check()
}

func TestJuniperConfirmedCommitIsFollowedByItsConfirmation(t *testing.T) {
	d, check := dialogue(t, "juniper", junosOperational, []exchange{
		{"configure exclusive\n", "Entering configuration mode\r\n" + junosConfig},
		{"delete interfaces ge-0/0/1 disable\n", junosConfig},
		{"commit check\n", "configuration check succeeds\r\n" + junosConfig},
		{"commit confirmed 5\n", "commit confirmed will be automatically rolled back in 5 minutes unless confirmed\r\ncommit complete\r\n" + junosConfig},
		{"commit\n", "commit complete\r\n" + junosConfig},
		{"exit\n", "Exiting configuration mode\r\n\r\n" + junosOperational},
	})
	if _, err := commit(t, d, commitScript(t, "delete interfaces ge-0/0/1 disable\n"), connector.CommitOptions{ConfirmMinutes: 5}); err != nil {
		t.Fatalf("confirmed commit rejected: %v", err)
	}
	check()
}

func TestJuniperPromptAloneDoesNotConfirmCommit(t *testing.T) {
	d, check := dialogue(t, "juniper", junosOperational, []exchange{
		{"configure exclusive\n", "Entering configuration mode\r\n" + junosConfig},
		{"set system ntp server 192.0.2.5\n", junosConfig},
		{"commit check\n", "configuration check succeeds\r\n" + junosConfig},
		{"commit\n", junosConfig},
		{"exit\n", "Exiting configuration mode\r\n\r\n" + junosOperational},
	})
	result, err := commit(t, d, commitScript(t, "set system ntp server 192.0.2.5\n"), connector.CommitOptions{})
	if !errors.Is(err, connector.ErrUnconfirmed) {
		t.Fatalf("prompt treated as commit confirmation: %v", err)
	}
	if len(result.Steps()) != 5 {
		t.Fatalf("accepted steps lost with the unconfirmed commit: %d", len(result.Steps()))
	}
	check()
}

func TestJuniperRejectedCheckNeverSendsCommit(t *testing.T) {
	d, check := dialogue(t, "juniper", junosOperational, []exchange{
		{"configure exclusive\n", "Entering configuration mode\r\n" + junosConfig},
		{"set system ntp server 192.0.2.5\n", junosConfig},
		{"commit check\n", "error: configuration check-out failed\r\n" + junosConfig},
	})
	result, err := commit(t, d, commitScript(t, "set system ntp server 192.0.2.5\n"), connector.CommitOptions{})
	if !errors.Is(err, connector.ErrDevice) {
		t.Fatalf("rejected check accepted: %v", err)
	}
	attempts := result.Attempts()
	if last := attempts[len(attempts)-1]; len(attempts) != 3 || last.Command().Text != "commit check" || last.Err() == nil || len(result.Steps()) != 2 {
		t.Fatalf("commands after a rejected check: attempts=%d steps=%d", len(attempts), len(result.Steps()))
	}
	if d.Connected() {
		t.Fatal("session kept after a rejected candidate; the exclusive candidate must be discarded with it")
	}
	check()
}

func TestPaloAltoCommitSendsExactCandidateSequence(t *testing.T) {
	const change = "set deviceconfig system ntp-servers primary-ntp-server ntp-server-address 192.0.2.5"
	d, check := dialogue(t, "palo_alto", panosOperational, []exchange{
		{"configure\n", "Entering configuration mode" + panosConfig},
		{change + "\n", panosConfig},
		{"commit\n", "Commit job 7 is in progress. Use Ctrl+C to return to command prompt\r\n.....55%....98%......100%\r\nConfiguration committed successfully\r\n" + panosConfig},
		{"exit\n", "Exiting configuration mode\r\n" + panosOperational},
	})
	if _, err := commit(t, d, commitScript(t, change+"\n"), connector.CommitOptions{}); err != nil {
		t.Fatalf("confirmed commit rejected: %v", err)
	}
	check()
}

func TestPaloAltoFailedCommitJobIsUnconfirmed(t *testing.T) {
	const change = "set deviceconfig system hostname fw"
	d, check := dialogue(t, "palo_alto", panosOperational, []exchange{
		{"configure\n", "Entering configuration mode" + panosConfig},
		{change + "\n", panosConfig},
		{"commit\n", "Commit job 8 is in progress. Use Ctrl+C to return to command prompt\r\n...100%\r\nValidation Error:\r\n deviceconfig -> system is invalid\r\nCommit failed\r\n" + panosConfig},
		{"exit\n", "Exiting configuration mode\r\n" + panosOperational},
	})
	if _, err := commit(t, d, commitScript(t, change+"\n"), connector.CommitOptions{}); !errors.Is(err, connector.ErrUnconfirmed) {
		t.Fatalf("failed commit job accepted: %v", err)
	}
	check()
}

func TestCommitOptionsAreValidatedBeforeAnyConnection(t *testing.T) {
	for _, tt := range []struct {
		name, platform string
		options        connector.CommitOptions
	}{
		{"junos confirmation out of range", "juniper", connector.CommitOptions{ConfirmMinutes: 61}},
		{"pan-os has no confirmed commit", "palo_alto", connector.CommitOptions{ConfirmMinutes: 5}},
	} {
		t.Run(tt.name, func(t *testing.T) {
			factory := func(context.Context, connector.ConnectionConfig) (io.ReadWriteCloser, error) {
				t.Error("a connection was opened for invalid commit options")
				return nil, errors.New("unexpected connection")
			}
			d, err := connector.New(lookupPlatform(t, tt.platform), connector.ConnectionConfig{Host: "fixture"}, connector.WithTransportFactory(factory))
			if err != nil {
				t.Fatal(err)
			}
			defer d.Close()
			if _, err = commit(t, d, commitScript(t, "set system host-name edge\n"), tt.options); !errors.Is(err, connector.ErrInvalid) {
				t.Fatalf("invalid commit options accepted: %v", err)
			}
		})
	}
}

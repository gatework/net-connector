package topology

import (
	"context"

	"github.com/gatework/net-connector/connector"
)

// The tests live in package topology_test because they build fixtures from
// the vendors catalog, which itself imports topology. These bridges expose
// the few internals those tests exercise.

// StageCommands returns the change, verification and persistence commands the
// client would send for changes.
func StageCommands(c *Client, changes []Change) (change, verify, persist []string, err error) {
	s, err := stagesFor(c.terminal, c.identity, c.writer, c.writeDenial, changes)
	return s.change, s.verify, s.persist, err
}

// SupportsWrite reports why the client's platform cannot change descriptions.
func SupportsWrite(c *Client) error { return c.supportsWrite() }

// NeighborsOnly runs neighbor discovery alone in one lease, without
// configuration collection, to isolate the neighbor command flow.
func NeighborsOnly(c *Client) (peers []Neighbor, result Result, err error) {
	if err = c.supportsNeighbors(); err != nil {
		return
	}
	err = c.device.WithOperation(context.Background(), func(ctx context.Context, op *connector.Operation) error {
		var e error
		peers, e = c.neighbors(ctx, op, &result)
		return e
	})
	return
}

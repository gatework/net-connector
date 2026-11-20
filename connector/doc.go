// Package connector opens logged-in device sessions and implements the
// netops ops.Dialer and ops.Session ports on top of them.
//
// A Dialer joins the four layers: it looks up the device's platform in the
// driver registry, its credentials in a netops credential.Provider, opens a
// stream with a transport and logs in with a terminal session interpreting
// the platform grammar. A Session then offers the operations every netops
// workflow needs (Collect, Write, Save, Checkpoint, Rollback) plus the
// richer ones some tools need (Run, Config, Commit, Export).
//
// Errors carry netops failure codes and stable reasons. Writes are never
// replayed: once a configuration command was sent, any failure leaves the
// outcome to the caller's verification.
package connector

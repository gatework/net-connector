package topology

import (
	"context"
	"errors"
	"slices"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/platform"
)

// Client binds stateless platform rules to a device. Constructing it performs no I/O.
type Client struct {
	device            *connector.Device
	neighborDiscovery NeighborDiscovery
	descriptionReader DescriptionReader
	identity          InterfaceIdentity
	writer            DescriptionWriter
	writeDenial       WriteRestriction
	terminal          connector.Terminal
}

// New binds the device to its declared topology capabilities without I/O.
func New(device *connector.Device, registry platform.Registry) (*Client, error) {
	if device == nil || registry == nil {
		return nil, ErrInvalid
	}
	d, e := registry.Lookup(device.PlatformName())
	if e != nil {
		return nil, e
	}
	p := d.Terminal()
	p.ConfigCommands = device.ConfigCommands()
	p.SaveCommands = device.SaveCommands()
	neighbors, _ := d.(NeighborDiscovery)
	descriptions, _ := d.(DescriptionReader)
	identity, _ := d.(InterfaceIdentity)
	writer, _ := d.(DescriptionWriter)
	writeDenial, _ := d.(WriteRestriction)
	return &Client{
		device:            device,
		neighborDiscovery: neighbors,
		descriptionReader: descriptions,
		identity:          identity,
		writer:            writer,
		writeDenial:       writeDenial,
		terminal:          p,
	}, nil
}

// Discover collects neighbors and descriptions within one device operation.
func (client *Client) Discover(ctx context.Context) (snapshot Snapshot, err error) {
	if err = client.supportsNeighbors(); err != nil {
		return
	}
	if err = client.supportsDescriptions(); err != nil {
		return
	}
	err = client.device.WithOperation(ctx, func(ctx context.Context, op *connector.Operation) error {
		var e error
		snapshot, e = client.discover(ctx, op)
		return e
	})
	return
}

// Audit compares collected evidence and preserves completed command receipts.
func (client *Client) Audit(ctx context.Context, opts FormatOptions) (audit Audit, err error) {
	if err = client.supportsNeighbors(); err != nil {
		return
	}
	if err = client.supportsDescriptions(); err != nil {
		return
	}
	if err = client.supportsIdentity(); err != nil {
		return
	}
	err = client.device.WithOperation(ctx, func(ctx context.Context, op *connector.Operation) error {
		s, e := client.discover(ctx, op)
		audit.Receipts = s.Receipts
		if e != nil {
			return e
		}
		a, e := buildAudit(client.device.Host(), client.terminal, client.identity, client.writer, client.writeDenial, s.Neighbors, s.Descriptions, opts)
		a.Receipts = s.Receipts
		audit = a
		return e
	})
	return
}

// Apply requires explicit confirmation and refuses stale evidence before the
// first configuration command. It never rolls back or replays uncertain writes.
func (client *Client) Apply(ctx context.Context, plan Plan, opts ApplyOptions) (result Result, err error) {
	if !opts.Confirmed {
		return result, newError("confirmation_required", "apply", ErrConfirmation)
	}
	plan = clonePlan(plan)
	if err = validatePlan(plan, client.device.Host(), client.terminal, client.identity, client.writer, client.writeDenial); err != nil {
		return
	}
	if opts.Execute.MaxOutputBytes < 0 {
		return result, ErrInvalid
	}
	if len(plan.Changes) == 0 {
		return
	}
	if err = client.supportsWrite(); err != nil {
		return
	}
	err = client.device.WithOperation(ctx, func(ctx context.Context, op *connector.Operation) error {
		return client.apply(ctx, op, plan, opts, &result)
	})
	return
}
func (client *Client) supportsNeighbors() error {
	if client.neighborDiscovery == nil {
		return newError("neighbor_discovery_unsupported", "discover", ErrUnsupported)
	}
	return nil
}
func (client *Client) supportsDescriptions() error {
	if client.descriptionReader == nil {
		return newError("description_unsupported", "discover", ErrUnsupported)
	}
	return nil
}
func (client *Client) supportsIdentity() error {
	if client.identity == nil {
		return newError("description_unsupported", "plan", ErrUnsupported)
	}
	return nil
}
func (client *Client) supportsWrite() error {
	if err := client.supportsIdentity(); err != nil {
		return err
	}
	return requireWriter(client.writer, client.writeDenial)
}
func (client *Client) discover(ctx context.Context, op *connector.Operation) (s Snapshot, err error) {
	r := Result{}
	defer func() { s.Receipts = r.Receipts }()
	s.Neighbors, err = client.neighbors(ctx, op, &r)
	if err != nil {
		return
	}
	s.Descriptions, err = client.descriptions(ctx, op, &r)
	return
}

func (client *Client) neighbors(ctx context.Context, op *connector.Operation, result *Result) ([]Neighbor, error) {
	if e := client.supportsNeighbors(); e != nil {
		return nil, e
	}
	status := ""
	prompt := ""
	if statusCommand := client.neighborDiscovery.NeighborStatusCommand(); statusCommand != "" {
		r, e := op.ExecuteCommand(ctx, connector.Command{Text: statusCommand}, connector.ExecuteOptions{})
		result.Receipts = append(result.Receipts, r.Steps()...)
		if e != nil {
			return nil, e
		}
		status, e = r.JoinedOutput()
		if e != nil {
			return nil, e
		}
		prompt, e = op.Prompt()
		if e != nil {
			return nil, e
		}
	}
	command, e := client.neighborDiscovery.NeighborCommand(status, prompt)
	if e != nil {
		return nil, structuredParseError(e, "discover")
	}
	r, e := op.ExecuteCommand(ctx, connector.Command{Text: command}, connector.ExecuteOptions{})
	result.Receipts = append(result.Receipts, r.Steps()...)
	if e != nil {
		return nil, e
	}
	output, e := r.JoinedOutput()
	if e != nil {
		return nil, e
	}
	return ParseNeighbors(client.neighborDiscovery, output)
}

func (client *Client) descriptions(ctx context.Context, op *connector.Operation, result *Result) (map[string]string, error) {
	if e := client.supportsDescriptions(); e != nil {
		return nil, e
	}
	r, e := op.RunningConfig(ctx)
	result.Receipts = append(result.Receipts, r.Steps()...)
	if e != nil {
		return nil, e
	}
	output, ok := r.Config()
	if !ok {
		return nil, connector.ErrIncomplete
	}
	return ParseDescriptions(client.descriptionReader, output)
}

func commandScript(texts []string) connector.Script {
	s := connector.Script{Name: "interface descriptions"}
	for _, text := range texts {
		s.Commands = append(s.Commands, connector.Command{Text: text})
	}
	return s
}
func (client *Client) apply(ctx context.Context, op *connector.Operation, p Plan, opts ApplyOptions, result *Result) error {
	s, e := stagesFor(client.terminal, client.identity, client.writer, client.writeDenial, p.Changes)
	if e != nil {
		return e
	}
	snapshot, e := client.discover(ctx, op)
	result.Receipts = append(result.Receipts, snapshot.Receipts...)
	if e != nil {
		return e
	}
	if e = revalidate(p, snapshot, client.identity); e != nil {
		return e
	}
	r, e := op.ExecuteScript(ctx, commandScript(s.change), opts.Execute)
	result.Receipts = append(result.Receipts, r.Steps()...)
	if e != nil {
		return e
	}
	if !slices.Equal(s.verify, client.device.ConfigCommands()) {
		return newError("verification_plan_changed", "verify", ErrVerification)
	}
	before := len(result.Receipts)
	updated, e := client.descriptions(ctx, op, result)
	if e != nil {
		return e
	}
	actual := []string{}
	for _, step := range result.Receipts[before:] {
		actual = append(actual, step.Command().Text)
	}
	if !slices.Equal(actual, s.verify) {
		return newError("verification_plan_changed", "verify", ErrVerification)
	}
	for _, c := range p.Changes {
		v, ok := updated[identityKey(client.identity, c.Interface)]
		if !ok || v != c.NewDescription {
			return newError("description_unconfirmed", "verify", ErrVerification)
		}
	}
	result.Verified = true
	r, e = op.SaveConfig(ctx, opts.Execute)
	result.Receipts = append(result.Receipts, r.Steps()...)
	if e != nil {
		return newError("persistence_unconfirmed", "persist", errors.Join(ErrPersistence, e))
	}
	result.Persisted = true
	return nil
}

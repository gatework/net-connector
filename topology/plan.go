package topology

import (
	"errors"
	"maps"
	"reflect"
	"slices"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/platform"
)

func identityKey(policy InterfaceIdentity, name string) string {
	if policy == nil {
		return InterfaceKey(name)
	}
	return policy.InterfaceKey(name)
}
func requireWriter(writer DescriptionWriter, denial WriteRestriction) error {
	if writer == nil {
		code := "description_unsupported"
		if denial != nil && denial.UnavailableCode() != "" {
			code = denial.UnavailableCode()
		}
		return newError(code, "plan", ErrUnsupported)
	}
	return nil
}
func formatDescription(peer Neighbor, opts FormatOptions) (string, error) {
	if opts.Formatter != nil {
		v, e := opts.Formatter(peer)
		if e != nil {
			return "", newError("formatter_failed", "plan", errors.Join(ErrInvalid, e))
		}
		return v, ValidateDescription(v)
	}
	return FormatDescription(peer, opts)
}
func evidenceFor(policy InterfaceIdentity, peers []Neighbor, descriptions map[string]string) (map[string]Evidence, error) {
	out := map[string]Evidence{}
	for _, peer := range peers {
		k := identityKey(policy, peer.LocalInterface)
		if _, ok := out[k]; ok {
			return nil, newError("ambiguous_neighbor", "plan", ErrParse)
		}
		if code := peer.IdentityIssue(); code != "" {
			return nil, newError(code, "plan", ErrParse)
		}
		old, ok := descriptions[k]
		if !ok {
			return nil, newError("interface_missing", "plan", ErrParse)
		}
		out[k] = Evidence{peer.NeighborName, peer.NeighborInterface, old}
	}
	return out, nil
}

// BuildPlan is pure: it opens no connections and resolves no credentials.
func BuildPlan(registry platform.Registry, host, vendor string, peers []Neighbor, descriptions map[string]string, opts FormatOptions) (Plan, error) {
	if registry == nil {
		return Plan{}, ErrInvalid
	}
	d, e := registry.Lookup(vendor)
	if e != nil {
		return Plan{}, e
	}
	identity, _ := d.(InterfaceIdentity)
	writer, _ := d.(DescriptionWriter)
	denial, _ := d.(WriteRestriction)
	return buildPlan(host, d.Terminal(), identity, writer, denial, peers, descriptions, opts)
}
func buildPlan(host string, terminal connector.Terminal, identity InterfaceIdentity, writer DescriptionWriter, denial WriteRestriction, peers []Neighbor, descriptions map[string]string, opts FormatOptions) (Plan, error) {
	if identity == nil {
		return Plan{}, newError("description_unsupported", "plan", ErrUnsupported)
	}
	if e := requireWriter(writer, denial); e != nil {
		return Plan{}, e
	}
	evidence, e := evidenceFor(identity, peers, descriptions)
	if e != nil {
		return Plan{}, e
	}
	p := Plan{Host: host, Platform: terminal.Name, Evidence: evidence, Changes: []Change{}, Commands: []string{}, Scope: "device"}
	for _, peer := range peers {
		old := descriptions[identityKey(identity, peer.LocalInterface)]
		proposed, e := formatDescription(peer, opts)
		if e != nil {
			return Plan{}, e
		}
		if EquivalentDescription(old, proposed) {
			continue
		}
		p.Changes = append(p.Changes, Change{identity.ConfigName(peer.LocalInterface), old, proposed, peer})
	}
	if len(p.Changes) > 0 {
		s, e := stagesFor(terminal, identity, writer, denial, p.Changes)
		if e != nil {
			return Plan{}, e
		}
		p.Commands = s.commands()
	}
	return p, nil
}

// BuildAudit preserves evidence issues separately and plans only verified interfaces.
func BuildAudit(registry platform.Registry, host, vendor string, peers []Neighbor, descriptions map[string]string, opts FormatOptions) (Audit, error) {
	if registry == nil {
		return Audit{}, ErrInvalid
	}
	d, e := registry.Lookup(vendor)
	if e != nil {
		return Audit{}, e
	}
	identity, _ := d.(InterfaceIdentity)
	if identity == nil {
		return Audit{}, ErrUnsupported
	}
	writer, _ := d.(DescriptionWriter)
	denial, _ := d.(WriteRestriction)
	return buildAudit(host, d.Terminal(), identity, writer, denial, peers, descriptions, opts)
}
func buildAudit(host string, terminal connector.Terminal, identity InterfaceIdentity, writer DescriptionWriter, denial WriteRestriction, peers []Neighbor, descriptions map[string]string, opts FormatOptions) (Audit, error) {
	if identity == nil {
		return Audit{}, ErrUnsupported
	}
	a := Audit{Comparisons: []Comparison{}, Issues: []Issue{}}
	p := Plan{Host: host, Platform: terminal.Name, Scope: "interfaces", Evidence: map[string]Evidence{}, Changes: []Change{}, Commands: []string{}}
	groups := map[string][]Neighbor{}
	order := []string{}
	for _, n := range peers {
		k := identityKey(identity, n.LocalInterface)
		if _, ok := groups[k]; !ok {
			order = append(order, k)
		}
		groups[k] = append(groups[k], n)
	}
	for _, k := range order {
		if err := auditGroup(&a, &p, identity, k, groups[k], descriptions, opts); err != nil {
			return a, err
		}
	}
	if requireWriter(writer, denial) == nil {
		if len(p.Changes) > 0 {
			s, e := stagesFor(terminal, identity, writer, denial, p.Changes)
			if e != nil {
				return a, e
			}
			p.Commands = s.commands()
		}
		a.Plan = &p
	} else {
		for _, r := range a.Comparisons {
			if r.Status != "matches" {
				a.ManualRequired = true
			}
		}
	}
	return a, nil
}

func auditGroup(a *Audit, p *Plan, identity InterfaceIdentity, k string, group []Neighbor, descriptions map[string]string, opts FormatOptions) error {
	n := group[0]
	old, exists := descriptions[k]
	row := Comparison{Interface: n.LocalInterface, Neighbor: n.NeighborName, Port: n.NeighborInterface, Status: "unverified"}
	if exists {
		row.Current = &old
	}
	code := ""
	switch {
	case len(group) != 1:
		code = "ambiguous_neighbor"
	case n.IdentityIssue() != "":
		code = n.IdentityIssue()
	case !exists:
		code = "interface_missing"
	}
	if code == "" {
		proposed, e := formatDescription(n, opts)
		var formatterError *Error
		if errors.As(e, &formatterError) && formatterError.Code == "formatter_failed" {
			return e
		}
		local := identity.ConfigName(n.LocalInterface)
		if e != nil || ValidateInterface(local) != nil {
			code = "unsafe_description"
		} else {
			row.Expected = &proposed
			match := EquivalentDescription(old, proposed)
			if opts.DescriptionMatcher != nil {
				match = opts.DescriptionMatcher(old, proposed, n)
			}
			row.Status = "content_mismatch"
			if match {
				row.Status = "matches"
			} else if old == "" {
				row.Status = "missing_description"
			}
			p.Evidence[k] = Evidence{n.NeighborName, n.NeighborInterface, old}
			if !match {
				p.Changes = append(p.Changes, Change{local, old, proposed, n})
			}
		}
	}
	if code != "" {
		row.Reason = code
		a.Issues = append(a.Issues, Issue{n.LocalInterface, code})
	}
	a.Comparisons = append(a.Comparisons, row)
	return nil
}

type stages struct{ change, verify, persist []string }

func (s stages) commands() []string {
	all := append([]string{}, s.change...)
	all = append(all, s.verify...)
	return append(all, s.persist...)
}
func stagesFor(terminal connector.Terminal, identity InterfaceIdentity, writer DescriptionWriter, denial WriteRestriction, changes []Change) (stages, error) {
	if identity == nil {
		return stages{}, newError("description_unsupported", "plan", ErrUnsupported)
	}
	if e := requireWriter(writer, denial); e != nil {
		return stages{}, e
	}
	s := stages{verify: slices.Clone(terminal.ConfigCommands), persist: slices.Clone(terminal.SaveCommands)}
	mode := writer.WriteMode()
	if mode.Enter == "" || mode.Leave == "" || mode.InterfaceExit == "" {
		return stages{}, newError("description_stages_unsupported", "plan", ErrUnsupported)
	}
	s.change = []string{mode.Enter}
	seen := map[string]bool{}
	for _, c := range changes {
		k := identityKey(identity, c.Interface)
		if ValidateInterface(c.Interface) != nil || ValidateDescription(c.NewDescription) != nil || seen[k] {
			return stages{}, ErrInvalid
		}
		seen[k] = true
		commands, e := writer.ChangeCommands(c.Interface, c.NewDescription)
		if e != nil || len(commands) == 0 {
			return stages{}, newError("description_stages_unsupported", "plan", errors.Join(ErrUnsupported, e))
		}
		s.change = append(s.change, commands...)
		s.change = append(s.change, mode.InterfaceExit)
	}
	s.change = append(s.change, mode.Leave)
	if len(s.verify) == 0 || len(s.persist) == 0 {
		return stages{}, newError("description_stages_unsupported", "plan", ErrUnsupported)
	}
	for _, v := range s.commands() {
		script, e := connector.ParseScript(v, "topology")
		if e != nil || len(script.Commands) != 1 || script.Commands[0].Text != v {
			return stages{}, ErrInvalid
		}
	}
	return s, nil
}

// ValidatePlan checks target identity, evidence and exact rendered commands without I/O.
func ValidatePlan(registry platform.Registry, p Plan, host, vendor string) error {
	if registry == nil {
		return ErrInvalid
	}
	d, e := registry.Lookup(vendor)
	if e != nil {
		return e
	}
	identity, _ := d.(InterfaceIdentity)
	writer, _ := d.(DescriptionWriter)
	denial, _ := d.(WriteRestriction)
	return validatePlan(p, host, d.Terminal(), identity, writer, denial)
}
func validatePlan(p Plan, host string, terminal connector.Terminal, identity InterfaceIdentity, writer DescriptionWriter, denial WriteRestriction) error {
	if p.Host != host || p.Platform != terminal.Name || (p.Scope != "device" && p.Scope != "interfaces") {
		return ErrInvalid
	}
	if len(p.Changes) == 0 {
		if len(p.Commands) != 0 {
			return ErrInvalid
		}
		return nil
	}
	s, e := stagesFor(terminal, identity, writer, denial, p.Changes)
	if e != nil {
		return e
	}
	if !slices.Equal(p.Commands, s.commands()) {
		return ErrInvalid
	}
	for _, c := range p.Changes {
		k := identityKey(identity, c.Interface)
		if c.Interface != identity.ConfigName(c.Neighbor.LocalInterface) || k != identityKey(identity, c.Neighbor.LocalInterface) || c.Neighbor.IdentityIssue() != "" || p.Evidence[k] != (Evidence{c.Neighbor.NeighborName, c.Neighbor.NeighborInterface, c.OldDescription}) {
			return ErrInvalid
		}
	}
	return nil
}
func clonePlan(p Plan) Plan {
	p.Evidence = maps.Clone(p.Evidence)
	p.Changes = slices.Clone(p.Changes)
	p.Commands = slices.Clone(p.Commands)
	p.Receipts = slices.Clone(p.Receipts)
	return p
}
func revalidate(p Plan, snapshot Snapshot, policy InterfaceIdentity) error {
	peers := snapshot.Neighbors
	descs := snapshot.Descriptions
	if p.Scope == "interfaces" {
		peers = nil
		for _, n := range snapshot.Neighbors {
			if _, ok := p.Evidence[identityKey(policy, n.LocalInterface)]; ok {
				peers = append(peers, n)
			}
		}
	}
	evidence, e := evidenceFor(policy, peers, descs)
	if e != nil || !reflect.DeepEqual(evidence, p.Evidence) {
		return newError("stale_plan", "apply", ErrStale)
	}
	byKey := map[string]Neighbor{}
	for _, n := range peers {
		byKey[identityKey(policy, n.LocalInterface)] = n
	}
	for _, c := range p.Changes {
		if byKey[identityKey(policy, c.Interface)] != c.Neighbor {
			return newError("stale_plan", "apply", ErrStale)
		}
	}
	return nil
}

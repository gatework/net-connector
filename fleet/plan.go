package fleet

import (
	"errors"
	"net/netip"
	"slices"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/gatework/net-connector/transfer"

	"github.com/gatework/net-connector/inventory"
	"github.com/gatework/net-connector/platform"
)

// ErrInvalidPlan identifies invalid rules, task plans, or report inputs.
var ErrInvalidPlan = errors.New("fleet: invalid plan")

// Mapping matches normalized inventory identity to a connector platform.
type Mapping struct {
	Vendor, Platform string
	OS, ModelPrefix  *string
}

// RuleOptions defines inventory filtering and explicit platform overrides.
type RuleOptions struct {
	Selection                        inventory.SelectionOptions
	PlatformOverrides, HostOverrides map[string]string
	Mappings                         []Mapping
}

// Rules owns validated selection and platform resolution rules.
type Rules struct {
	selection        inventory.Selection
	vendors, hosts   map[string]string
	mappings         []Mapping
	registered       map[string]struct{}
	platformResolver PlatformResolver
	registry         platform.Registry
}

// PlatformResolver belongs to Fleet, which consumes platform recognition.
type PlatformResolver interface {
	ResolvePlatform(identity platform.Identity) (platform string, found bool)
}

// NewRules validates and owns rules against an explicit platform registry.
func NewRules(o RuleOptions, registry platform.Registry) (*Rules, error) {
	if registry == nil {
		return nil, ErrInvalidPlan
	}
	names := registry.Names()
	if len(names) == 0 {
		return nil, ErrInvalidPlan
	}
	s, e := inventory.NewSelection(o.Selection)
	if e != nil {
		return nil, e
	}
	registered := make(map[string]struct{}, len(names))
	for _, name := range names {
		registered[name] = struct{}{}
	}
	r := &Rules{
		selection:        s,
		vendors:          map[string]string{},
		hosts:            map[string]string{},
		registered:       registered,
		platformResolver: platformResolver(registry),
		registry:         registry,
	}
	if err := r.configure(o); err != nil {
		return nil, err
	}
	return r, nil
}

func platformResolver(registry platform.Registry) PlatformResolver {
	resolver, _ := registry.(PlatformResolver)
	return resolver
}

// Resolve returns the registered platform selected for an inventory device.
func (r *Rules) Resolve(d inventory.Device) string {
	if a, e := netip.ParseAddr(d.IP); e == nil {
		if v := r.hosts[a.String()]; v != "" {
			return v
		}
	}
	label, os, model := platform.NormalizeLabel(d.Vendor), platform.NormalizeLabel(d.OS), platform.NormalizeLabel(d.Model)
	for _, m := range r.mappings {
		if m.Vendor == label && (m.OS == nil || *m.OS == os) && (m.ModelPrefix == nil || strings.HasPrefix(model, *m.ModelPrefix)) {
			return m.Platform
		}
	}
	if v := r.vendors[label]; v != "" {
		return v
	}
	if r.platformResolver == nil {
		return ""
	}
	name, found := r.platformResolver.ResolvePlatform(platform.Identity{Vendor: d.Vendor, OS: d.OS, Model: d.Model})
	if !found {
		return ""
	}
	if _, registered := r.registered[name]; !registered {
		return ""
	}
	return name
}

// Record contains normalized device identity and any planning issue.
type Record struct{ Host, SourceIP, Name, Platform, SourceVendor, Model, OS, OSVersion, Serial, Issue string }

// Record normalizes a device and records any reason it cannot be selected.
func (r *Rules) Record(d inventory.Device) Record {
	v := Record{SourceIP: d.IP, Name: strings.TrimSpace(d.Name), Platform: r.Resolve(d), SourceVendor: d.Vendor, Model: d.Model, OS: d.OS, OSVersion: d.OSVersion, Serial: d.Serial}
	if v.Name == "" {
		v.Name = strings.TrimSpace(d.DNS)
	}
	a, e := netip.ParseAddr(d.IP)
	if e != nil || a.Zone() != "" {
		v.Issue = string(planStatusInvalidAddress)
	} else {
		v.Host = a.String()
	}
	d.IP, d.Name, d.Vendor = v.Host, v.Name, v.Platform
	if v.Issue == "" && !r.selection.Evaluate(d).Selected() {
		v.Issue = string(planStatusFiltered)
	}
	if v.Issue == "" && v.Platform == "" {
		v.Issue = string(planStatusUnsupportedVendor)
	}
	return v
}
func (r *Rules) configure(o RuleOptions) error {
	valid := func(v string) bool { _, ok := r.registered[v]; return ok }
	for _, list := range [][]string{o.Selection.IncludePlatforms, o.Selection.ExcludePlatforms} {
		for _, v := range list {
			if !valid(v) {
				return ErrInvalidPlan
			}
		}
	}
	for k, v := range o.PlatformOverrides {
		k = platform.NormalizeLabel(k)
		if k == "" || !valid(v) {
			return ErrInvalidPlan
		}
		if old, ok := r.vendors[k]; ok && old != v {
			return ErrInvalidPlan
		}
		r.vendors[k] = v
	}
	if err := r.configureHosts(o.HostOverrides); err != nil {
		return err
	}
	return r.configureMappings(o.Mappings)
}

func (r *Rules) configureHosts(overrides map[string]string) error {
	valid := func(v string) bool { _, ok := r.registered[v]; return ok }
	for k, v := range overrides {
		a, e := netip.ParseAddr(k)
		if e != nil || a.Zone() != "" || !valid(v) {
			return ErrInvalidPlan
		}
		k = a.String()
		if old, ok := r.hosts[k]; ok && old != v {
			return ErrInvalidPlan
		}
		r.hosts[k] = v
	}
	return nil
}

func (r *Rules) configureMappings(mappings []Mapping) error {
	valid := func(v string) bool { _, ok := r.registered[v]; return ok }
	for _, m := range mappings {
		m.Vendor = platform.NormalizeLabel(m.Vendor)
		if m.Vendor == "" || !valid(m.Platform) {
			return ErrInvalidPlan
		}
		if m.OS != nil {
			v := platform.NormalizeLabel(*m.OS)
			m.OS = &v
		}
		if m.ModelPrefix != nil {
			v := platform.NormalizeLabel(*m.ModelPrefix)
			m.ModelPrefix = &v
		}
		r.mappings = append(r.mappings, m)
	}
	return nil
}

// Filename returns the safe "<name>-<address>.txt" artifact name of the device.
func (r Record) Filename() (string, error) {
	a, e := netip.ParseAddr(r.Host)
	if e != nil || a.Zone() != "" {
		return "", ErrInvalidPlan
	}
	base := strings.ReplaceAll(a.String(), ":", "_") + ".txt"
	var b strings.Builder
	dash := false
	for _, c := range strings.ToValidUTF8(r.Name, "-") {
		valid := unicode.IsLetter(c) || unicode.IsNumber(c) || strings.ContainsRune("._-", c)
		if valid {
			b.WriteRune(c)
			dash = false
		} else if !dash {
			b.WriteByte('-')
			dash = true
		}
	}
	label := b.String()
	if len(label) > 160 {
		label = label[:160]
		for !utf8.ValidString(label) {
			label = label[:len(label)-1]
		}
	}
	label = strings.Trim(label, "._-")
	if label == "" {
		label = "unnamed"
	}
	return label + "-" + base, nil
}

// Task binds an inventory entry to its transfer target.
type Task struct {
	Index  int
	Device Record
	Target transfer.Target
}

// PlanEntry records one inventory device and its planning status.
type PlanEntry struct {
	Device Record
	Status string
}

// PlanOptions defines admission, sampling and transfer arbitration policy.
type PlanOptions struct {
	// LimitPerPlatform samples at most this many admitted devices per platform
	// (0 to 5); zero admits all.
	LimitPerPlatform int
	// Admit decides, without I/O, whether the operation supports a device. A
	// non-empty result is the device's skip status. Nil admits every device.
	Admit func(record Record, p platform.Platform) (skip string)
	// Target resolves the transfer destination of an admitted device. When set,
	// devices that would overwrite one another's remote file are arbitrated.
	Target func(Record) (transfer.Target, error)
	// ReuseDestination reports whether a platform may share one fixed remote
	// file name between devices. Nil never allows it.
	ReuseDestination func(p platform.Platform) bool
}

// Plan owns inventory outcomes and the ready tasks derived from them.
type Plan struct {
	entries   []PlanEntry
	tasks     []Task
	transfers map[int]transfer.Target
}

// NewPlan classifies the inventory, admits devices for one operation, samples
// them per platform and arbitrates duplicate hosts and destinations.
func NewPlan(rows []inventory.Device, rules *Rules, o PlanOptions) (Plan, error) {
	if rules == nil || o.LimitPerPlatform < 0 || o.LimitPerPlatform > 5 {
		return Plan{}, ErrInvalidPlan
	}
	p := Plan{transfers: map[int]transfer.Target{}}
	counts := map[string]int{}
	for _, d := range rows {
		r := rules.Record(d)
		p.entries = append(p.entries, PlanEntry{Device: r, Status: string(planStatus(r.Issue))})
		if r.Host != "" {
			counts[r.Host]++
		}
	}
	platforms, groups, groupOrder, err := preparePlanEntries(&p, counts, rules, o)
	if err != nil {
		return Plan{}, err
	}
	arbitration := arbitratePlan(&p, groups, groupOrder, o.LimitPerPlatform)
	preparePlanTasks(&p, arbitration, platforms, o)
	return p, nil
}

// Entries returns a copy of the inventory outcomes in inventory order.
func (p Plan) Entries() []PlanEntry { return slices.Clone(p.entries) }

// ErrMissingCredentials reports a device with no configured login credentials.
var ErrMissingCredentials = errors.New("fleet: missing device credentials")

// Tasks returns a copy of the ready tasks in inventory order.
func (p Plan) Tasks() []Task { return slices.Clone(p.tasks) }

// preparePlanEntries admits each classified device and groups the admitted
// ones by platform. Every platform is looked up once per plan.
func preparePlanEntries(p *Plan, counts map[string]int, rules *Rules, o PlanOptions) (map[string]platform.Platform, map[string][]int, []string, error) {
	platforms := make(map[string]platform.Platform)
	groups := map[string][]int{}
	groupOrder := []string{}
	for i := range p.entries {
		entry := &p.entries[i]
		r := entry.Device
		if counts[r.Host] > 1 && r.Host != "" {
			entry.Status = string(planStatusDuplicateHost)
		}
		if entry.Status != "" {
			continue
		}
		declared, ok := platforms[r.Platform]
		if !ok {
			var err error
			declared, err = rules.registry.Lookup(r.Platform)
			if err != nil {
				return nil, nil, nil, ErrInvalidPlan
			}
			platforms[r.Platform] = declared
		}
		if o.Admit != nil {
			if skip := o.Admit(r, declared); skip != "" {
				entry.Status = skip
				continue
			}
		}
		if o.Target != nil {
			target, e := o.Target(r)
			if e != nil {
				return nil, nil, nil, e
			}
			if target.Server == "" || target.Path == "" {
				return nil, nil, nil, ErrInvalidPlan
			}
			p.transfers[i] = target
		}
		if _, exists := groups[r.Platform]; !exists {
			groupOrder = append(groupOrder, r.Platform)
		}
		groups[r.Platform] = append(groups[r.Platform], i)
	}
	return platforms, groups, groupOrder, nil
}

// arbitratePlan uses sampling order; tasks and outcomes retain inventory order.
func arbitratePlan(p *Plan, groups map[string][]int, groupOrder []string, limit int) []int {
	arbitration := []int{}
	if limit > 0 {
		for _, vendor := range groupOrder {
			indices := groups[vendor]
			slices.SortStableFunc(indices, func(a, b int) int { return strings.Compare(p.entries[a].Device.Host, p.entries[b].Device.Host) })
			for n, i := range indices {
				if n >= limit {
					p.entries[i].Status = string(planStatusSampleLimit)
				} else {
					arbitration = append(arbitration, i)
				}
			}
		}
	}
	if limit == 0 {
		for i, e := range p.entries {
			if e.Status == "" {
				arbitration = append(arbitration, i)
			}
		}
	}
	return arbitration
}

func preparePlanTasks(p *Plan, arbitration []int, platforms map[string]platform.Platform, o PlanOptions) {
	type destination [2]string
	owners := map[destination]int{}
	if o.Target != nil {
		for _, i := range arbitration {
			target := p.transfers[i]
			key := destination{target.Server, target.Path}
			if _, exists := owners[key]; !exists {
				owners[key] = i
			}
		}
	}
	for i := range p.entries {
		e := &p.entries[i]
		if e.Status != "" {
			continue
		}
		target := p.transfers[i]
		reuse := o.ReuseDestination != nil && o.ReuseDestination(platforms[e.Device.Platform])
		if o.Target != nil && owners[destination{target.Server, target.Path}] != i && !reuse {
			e.Status = string(planStatusRemoteFilenameCollision)
			continue
		}
		e.Status = string(planStatusReady)
		p.tasks = append(p.tasks, Task{Index: i, Device: e.Device, Target: target})
	}
}

package driver

import (
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/gatework/net-connector/terminal"
	"github.com/gatework/netops/device"
)

// ErrUnsupported reports a capability the platform does not declare.
var ErrUnsupported = errors.New("driver: unsupported")

// Driver is one platform.
type Driver interface {
	// Platform is the canonical key, such as "h3c" or "cisco_nxos".
	Platform() string
	// Grammar returns the platform dialect; callers may modify the copy.
	Grammar() terminal.Grammar
}

// Classifier recognizes the platform from a normalized inventory identity.
type Classifier interface {
	Match(id device.Identity) bool
}

// ConfigReader reads the running configuration.
type ConfigReader interface {
	// ConfigSteps returns the commands that read the configuration, in
	// order. Most platforms need one; PAN-OS needs a guarded sequence.
	ConfigSteps() []terminal.Command
	// CleanConfig checks the responses of every step and returns the
	// configuration text, without banners and trailers. It fails when the
	// responses do not prove a complete running configuration.
	CleanConfig(responses []terminal.Response) (string, error)
}

// Saver persists the running configuration.
type Saver interface {
	SaveProcedure() terminal.Procedure
}

// CommitOptions configure a candidate commit.
type CommitOptions struct {
	// Confirm, when positive, commits with automatic rollback unless
	// confirmed within this many minutes (Junos "commit confirmed").
	Confirm int
	Comment string
}

// Committer commits a candidate configuration. Its procedure enters the
// candidate, sends the body, checks and commits.
type Committer interface {
	CommitProcedure(body []string, o CommitOptions) (terminal.Procedure, error)
}

// Checkpointer takes and restores named configuration checkpoints.
type Checkpointer interface {
	CheckpointProcedure(name string) (terminal.Procedure, error)
	RollbackProcedure(name string) (terminal.Procedure, error)
}

// Export is where an Exporter uploads the configuration.
type Export struct {
	Protocol string // "tftp" (default) or "scp"/"ftp" where supported
	Server   string // server address
	File     string // remote file name
	VRF      string // management VRF, when the platform needs one
	Source   string // source interface or file, when the platform needs one
	Timeout  time.Duration
}

// Exporter uploads the configuration from the device itself.
type Exporter interface {
	ExportProcedure(e Export) (terminal.Procedure, error)
}

// LoginState is what a LoginInspector learned.
type LoginState struct {
	// Role is the high-availability role, such as "active" or "standby".
	Role string
	// Writable is false when the device must not be changed through this
	// session, for example an HA standby.
	Writable bool
}

// LoginInspector reads device state after login.
type LoginInspector interface {
	AfterLogin(banner, prompt string) (LoginState, error)
}

// ReadOnly decides before connecting whether a command only reads.
type ReadOnly interface {
	ReadOnly(command string) bool
}

// Base implements Driver; vendor types embed it and add capabilities.
type Base struct {
	key     string
	grammar terminal.Grammar
}

// NewBase validates grammar and binds it to key.
func NewBase(key string, g terminal.Grammar) Base {
	if err := g.Validate(); err != nil {
		panic(fmt.Sprintf("driver: %s grammar: %v", key, err))
	}
	return Base{key: key, grammar: g}
}

// Platform returns the key.
func (b Base) Platform() string { return b.key }

// Grammar returns a copy of the grammar.
func (b Base) Grammar() terminal.Grammar { return clone(b.grammar) }

func clone(g terminal.Grammar) terminal.Grammar {
	g.Login.Banner = slices.Clone(g.Login.Banner)
	g.Login.Username = slices.Clone(g.Login.Username)
	g.Login.Password = slices.Clone(g.Login.Password)
	g.Login.Failed = slices.Clone(g.Login.Failed)
	g.Login.Locked = slices.Clone(g.Login.Locked)
	g.Login.Expired = slices.Clone(g.Login.Expired)
	g.Prompts = slices.Clone(g.Prompts)
	if g.Privilege != nil {
		p := *g.Privilege
		p.Password, p.Failed = slices.Clone(p.Password), slices.Clone(p.Failed)
		g.Privilege = &p
	}
	g.Preparation = slices.Clone(g.Preparation)
	g.Pager = slices.Clone(g.Pager)
	g.Errors = slices.Clone(g.Errors)
	g.Warnings = slices.Clone(g.Warnings)
	g.Async = slices.Clone(g.Async)
	g.Questions = slices.Clone(g.Questions)
	g.Rules = slices.Clone(g.Rules)
	return g
}

// Override returns a driver whose grammar is d's modified by edit, for
// site-specific prompts or banners. Capabilities of d stay reachable
// through Unwrap.
//
//nolint:iface // a decorator returns the interface it decorates
func Override(d Driver, edit func(*terminal.Grammar)) (Driver, error) {
	g := d.Grammar()
	edit(&g)
	if err := g.Validate(); err != nil {
		return nil, fmt.Errorf("driver: %s override: %w", d.Platform(), err)
	}
	return overridden{Driver: d, g: g}, nil
}

type overridden struct {
	Driver
	g terminal.Grammar
}

func (o overridden) Grammar() terminal.Grammar { return clone(o.g) }
func (o overridden) Unwrap() Driver            { return o.Driver }

// As finds a capability C on d or on the drivers it wraps.
func As[C any](d Driver) (C, bool) {
	for d != nil {
		if c, ok := d.(C); ok {
			return c, true
		}
		u, ok := d.(interface{ Unwrap() Driver })
		if !ok {
			break
		}
		d = u.Unwrap()
	}
	var zero C
	return zero, false
}

// Verbs is a ReadOnly that accepts commands starting with one of its
// verbs, with only display filters after a pipe.
type Verbs []string

var (
	pipeFilter = regexp.MustCompile(`(?i)^\s*(?:include|exclude|begin|section|count|no-more|i|e|b|s)\b`)
	// Anything that may write a file is not a read: shell redirection,
	// Comware/VRP "redirect" and pipes that tee, append or save.
	redirect = regexp.MustCompile(`(?i)>|redirect|\b(?:tee|append)\b|\|\s*save\b`)
)

// ReadOnly reports whether command is a read command.
func (v Verbs) ReadOnly(command string) bool {
	command = strings.TrimSpace(command)
	head, filters, _ := strings.Cut(command, "|")
	fields := strings.Fields(head)
	if len(fields) == 0 || !slices.ContainsFunc(v, func(verb string) bool { return strings.EqualFold(fields[0], verb) }) {
		return false
	}
	if redirect.MatchString(command) {
		return false
	}
	for f := range strings.SplitSeq(filters, "|") {
		if strings.TrimSpace(f) != "" && !pipeFilter.MatchString(f) {
			return false
		}
	}
	return true
}

// Matcher is a Classifier built from regular expressions over the
// normalized identity; empty expressions match anything.
type Matcher struct {
	Vendor, OS, Model *regexp.Regexp
	// Any lists alternative matchers; the identity matches when Vendor/OS/
	// Model all match, or when any alternative does.
	Any []Matcher
}

// Match implements Classifier.
func (m Matcher) Match(id device.Identity) bool {
	ok := func(re *regexp.Regexp, s string) bool { return re == nil || re.MatchString(s) }
	if (m.Vendor != nil || m.OS != nil || m.Model != nil) && ok(m.Vendor, id.Vendor) && ok(m.OS, id.OS) && ok(m.Model, id.Model) {
		return true
	}
	return slices.ContainsFunc(m.Any, func(a Matcher) bool { return a.Match(id) })
}

// Capability names a declared capability.
type Capability string

// Capabilities, in report order.
const (
	CapConfig     Capability = "config"
	CapSave       Capability = "save"
	CapExport     Capability = "export"
	CapCheckpoint Capability = "checkpoint"
	CapCommit     Capability = "commit"
	CapLogin      Capability = "login"
	CapReadOnly   Capability = "readonly"
)

// Capabilities lists what d declares, in report order: the capability
// matrix a tool shows operators.
func Capabilities(d Driver) []Capability {
	var out []Capability
	add := func(ok bool, c Capability) {
		if ok {
			out = append(out, c)
		}
	}
	_, config := As[ConfigReader](d)
	_, save := As[Saver](d)
	_, export := As[Exporter](d)
	_, checkpoint := As[Checkpointer](d)
	_, commit := As[Committer](d)
	_, login := As[LoginInspector](d)
	_, readOnly := As[ReadOnly](d)
	add(config, CapConfig)
	add(save, CapSave)
	add(export, CapExport)
	add(checkpoint, CapCheckpoint)
	add(commit, CapCommit)
	add(login, CapLogin)
	add(readOnly, CapReadOnly)
	return out
}

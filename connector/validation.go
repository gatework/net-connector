package connector

import (
	"regexp"
	"strings"

	expect "github.com/gatework/go-expect"
	"github.com/gatework/net-connector/internal/nilcheck"
)

// Validate checks terminal declarations without applying defaults.
func (t Terminal) Validate() error {
	if t.Name == "" || t.LoginPrompt.IsZero() || t.CommandPrompt.IsZero() || t.CommandTimeout < 0 {
		return ErrInvalid
	}
	for _, r := range []expect.Pattern{t.LoginPrompt, t.CommandPrompt, t.UsernamePrompt, t.PasswordPrompt, t.PrivilegePrompt, t.Pager} {
		if !r.IsZero() && r.ValidateText() != nil {
			return ErrInvalid
		}
	}
	if t.PrivilegeCommand != "" {
		if e := (Command{Text: t.PrivilegeCommand}).validate(); e != nil {
			return e
		}
		if t.PrivilegePrompt.IsZero() {
			return ErrInvalid
		}
	}
	for _, replies := range [][]Interaction{t.LoginInteractions, t.Interactions} {
		if e := validateInteractions(replies); e != nil {
			return e
		}
	}
	if t.PrivilegedPrompt != nil && t.PrivilegedPrompt.MatchString("") {
		return ErrInvalid
	}
	if err := t.validateErrorPatterns(); err != nil {
		return err
	}
	for _, arg := range t.LegacyCryptoArguments {
		if arg == "" || strings.ContainsAny(arg, "\x00\r\n") {
			return ErrInvalid
		}
	}
	for _, commands := range [][]string{t.ConfigCommands, t.SaveCommands} {
		for _, text := range commands {
			if e := (Command{Text: text}).validate(); e != nil {
				return e
			}
		}
	}
	return nil
}

func (t Terminal) validateErrorPatterns() error {
	for _, list := range [][]*regexp.Regexp{t.AuthenticationErrors, t.CommandErrors} {
		for _, r := range list {
			if r == nil || r.MatchString("") {
				return ErrInvalid
			}
		}
	}
	return nil
}

// jumpHostPattern accepts "[user@]host[:port]" and never a leading "-", so the
// value cannot be read as another ssh option.
var jumpHostPattern = regexp.MustCompile(`^(?:[A-Za-z0-9._][A-Za-z0-9._-]*@)?(?:[A-Za-z0-9][A-Za-z0-9.-]*|\[[0-9A-Fa-f:.]+\])(?::[0-9]{1,5})?$`)

// Validate checks the target and all connection options without allocating a Device.
func (c ConnectionConfig) Validate() error {
	if strings.TrimSpace(c.Host) == "" || strings.ContainsAny(c.Host, "\r\n\x00\t ") || strings.HasPrefix(c.Host, "-") {
		return ErrInvalid
	}
	return c.ValidateOptions()
}

// ValidateOptions checks reusable options without requiring a bound Host.
func (c ConnectionConfig) ValidateOptions() error {
	if c.Logger != nil && nilcheck.IsNil(c.Logger) {
		return ErrInvalid
	}
	for _, value := range []string{c.Username, c.Password, c.EnablePassword, c.KeyPassphrase, c.IdentityFile, c.KnownHosts, c.SSHPath, c.TelnetPath} {
		if strings.ContainsAny(value, "\r\n\x00") {
			return ErrInvalid
		}
	}
	if c.Port < 0 || c.Port > 65535 || c.ConnectRetries < 0 || c.ConnectRetries > 5 {
		return ErrInvalid
	}
	if c.JumpHost != "" && (!jumpHostPattern.MatchString(c.JumpHost) || c.Protocol == ProtocolTelnet || c.AllowTelnetFallback) {
		return ErrInvalid
	}
	if c.LineEnding != "" && c.LineEnding != "\n" && c.LineEnding != "\r" && c.LineEnding != "\r\n" {
		return ErrInvalid
	}
	if c.Protocol != "" && c.Protocol != ProtocolSSH && c.Protocol != ProtocolTelnet {
		return ErrInvalid
	}
	switch c.HostKeyPolicy {
	case "", HostKeyStrict, HostKeyAcceptNew:
	case HostKeyReplace:
		if strings.TrimSpace(c.KnownHosts) == "" {
			return ErrInvalid
		}
	default:
		return ErrInvalid
	}
	if c.LogLevel != "" && c.LogLevel.priority() < 0 {
		return ErrInvalid
	}
	if c.LoginTimeout < 0 || c.CommandTimeout < 0 || c.WriteTimeout < 0 || c.MaxOutputBytes < 0 || c.MaxScriptOutputBytes < 0 {
		return ErrInvalid
	}
	return validateInteractions(c.Challenges)
}

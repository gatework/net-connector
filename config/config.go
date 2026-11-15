package config

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"maps"
	"math"
	"os"
	"path/filepath"
	"strings"

	"github.com/gatework/net-connector/internal/batchreport"
)

// Options defines configuration locations and explicit input layers.
type Options struct {
	Name, CWD, Home, Program, ConfigFile, EnvFile string
	Directories                                   []string
	Environment                                   map[string]string
	Overrides, Defaults                           map[string]any
	AllowMissing                                  bool
}

// Snapshot owns a validated configuration and its separate credential environment.
type Snapshot struct {
	data                map[string]any
	environment         map[string]string
	files, envFiles     []string
	fields              map[string]string
	configPath, envPath string
	applicable          bool
}

// Public returns an independent copy of the public configuration.
func (s Snapshot) Public() map[string]any {
	public, _ := cloneValue(s.data).(map[string]any) // cloneValue preserves the map type
	return public
}

// Value returns an owned value at a dot-separated configuration path.
func (s Snapshot) Value(path string) any {
	var v any = s.data
	for key := range strings.SplitSeq(path, ".") {
		m, ok := v.(map[string]any)
		if !ok {
			return nil
		}
		v = m[key]
	}
	return cloneValue(v)
}

// Secret explicitly returns a credential environment value.
func (s Snapshot) Secret(key string) string { return s.environment[key] }

// Environment returns a copy of the effective credential environment.
func (s Snapshot) Environment() map[string]string {
	m := map[string]string{}
	maps.Copy(m, s.environment)
	return m
}

// Sources returns configuration provenance without credential values.
func (s Snapshot) Sources() map[string]any {
	fields := map[string]string{}
	maps.Copy(fields, s.fields)
	return map[string]any{"configuration_files": append([]string{}, s.files...), "environment_files": append([]string{}, s.envFiles...), "fields": fields}
}

// InitPaths returns the configuration and environment initialization paths.
func (s Snapshot) InitPaths() (string, string) { return s.configPath, s.envPath }

// String identifies the snapshot without exposing its values.
func (s Snapshot) String() string { return "config.Snapshot" }

// GoString formats the same safe metadata as String.
func (s Snapshot) GoString() string { return s.String() }

// MarshalJSON encodes public configuration without the credential environment.
func (s Snapshot) MarshalJSON() ([]byte, error) { return json.Marshal(s.data) }

var pathFields = map[string]bool{"inventory.file": true, "netdisco.cache_directory": true, "netdisco.db_sslrootcert": true, "backup.directory": true, "topology.directory": true, "ssh.known_hosts": true, "ssh.log_directory": true, "tftp.verification_root": true}

func absolutePath(path, base, home string) string {
	if path == "~" {
		return home
	}
	if strings.HasPrefix(path, "~/") {
		return filepath.Join(home, path[2:])
	}
	if filepath.IsAbs(path) {
		return filepath.Clean(path)
	}
	return filepath.Join(base, path)
}
func pathValue(v, base, home string) (string, error) {
	if strings.ContainsRune(v, 0) {
		return "", ErrInvalid
	}
	if strings.Contains(v, "://") {
		return v, nil
	}
	return absolutePath(v, base, home), nil
}
func resolvePaths(m map[string]any, base, home, prefix string) error {
	for k, v := range m {
		key := k
		if prefix != "" {
			key = prefix + "." + k
		}
		if child, ok := v.(map[string]any); ok {
			if e := resolvePaths(child, base, home, key); e != nil {
				return e
			}
		} else if pathFields[key] || strings.HasPrefix(key, "tftp.verification_roots.") {
			if s, ok := v.(string); ok && s != "" {
				if (key == "ssh.known_hosts" && s == "inherit") || (key == "netdisco.db_sslrootcert" && s == "system") {
					continue
				}
				p, e := pathValue(s, base, home)
				if e != nil {
					return e
				}
				m[k] = p
			}
		}
	}
	return nil
}
func resolveEnvironmentPaths(m map[string]string, base, home string) error {
	for path, f := range schema {
		if !pathFields[path] {
			continue
		}
		v, ok := m[f.Env]
		if !ok || v == "" {
			continue
		}
		if (path == "ssh.known_hosts" && v == "inherit") || (path == "netdisco.db_sslrootcert" && v == "system") {
			continue
		}
		p, e := pathValue(v, base, home)
		if e != nil {
			return e
		}
		m[f.Env] = p
	}
	if v := m["NC_CONFIG"]; strings.TrimSpace(v) != "" {
		p, e := pathValue(v, base, home)
		if e != nil {
			return e
		}
		m["NC_CONFIG"] = p
	}
	return nil
}
func uniquePaths(paths []string, last string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, p := range paths {
		if p != "" && p != last && !seen[p] {
			out = append(out, p)
			seen[p] = true
		}
	}
	if last != "" {
		out = append(out, last)
	}
	return out
}

// Load loads and freezes the configured layers, checking cancellation
// between discovery, file reads and layer decoding. Filesystem calls and bounded
// parsers remain synchronous; cancellation cannot interrupt a blocked syscall.
func Load(ctx context.Context, o Options) (snapshot Snapshot, err error) {
	s := Snapshot{data: map[string]any{}, environment: map[string]string{}, fields: map[string]string{}}
	if ctx == nil {
		return s, ErrInvalid
	}
	defer func() {
		if canceled := ctx.Err(); canceled != nil && !errors.Is(err, canceled) {
			err = errors.Join(err, canceled)
		}
	}()
	if err := ctx.Err(); err != nil {
		return s, err
	}
	if o.Name != "backup" && o.Name != "topology" {
		return s, ErrInvalid
	}
	l := &loader{ctx: ctx, o: o, s: &s, envOrigins: map[string]string{}}
	for _, step := range []func() error{l.ownLayers, l.resolveLocations, l.readEnvironmentFiles, l.readConfigurationFiles, l.mergeLayers, l.finish} {
		if err := step(); err != nil {
			return s, err
		}
	}
	return s, ctx.Err()
}

// loader is the state of one Load call.
type loader struct {
	ctx        context.Context //nolint:containedctx // scoped to one Load call
	o          Options
	s          *Snapshot
	process    map[string]string
	user       string   // the user configuration directory
	dirs       []string // the configuration search directories
	envFile    string   // the selected .env file, if any
	envOrigins map[string]string
	selected   string // the selected configuration file, if any
	yamlData   map[string]any
}

// ownLayers validates and copies the caller's default and override layers
// before any container is walked or merged.
func (l *loader) ownLayers() error {
	for _, layer := range []*map[string]any{&l.o.Defaults, &l.o.Overrides} {
		if err := l.ctx.Err(); err != nil {
			return err
		}
		owned, e := copyPlain(*layer)
		if e != nil {
			return e
		}
		*layer, _ = owned.(map[string]any)
	}
	return l.ctx.Err()
}

// resolveLocations makes the home and working directories absolute, copies
// the process environment and settles the search directories.
func (l *loader) resolveLocations() error {
	o := &l.o
	actualCWD, e := os.Getwd()
	if e != nil {
		return e
	}
	if o.Home == "" {
		if o.Home, e = os.UserHomeDir(); e != nil {
			return e
		}
	}
	o.Home = absolutePath(o.Home, actualCWD, o.Home)
	if !filepath.IsAbs(o.Home) {
		return ErrInvalid
	}
	if o.CWD == "" {
		o.CWD = actualCWD
	}
	o.CWD = absolutePath(o.CWD, actualCWD, o.Home)
	l.process = map[string]string{}
	maps.Copy(l.process, o.Environment)
	if e := resolveEnvironmentPaths(l.process, o.CWD, o.Home); e != nil {
		return e
	}
	user := l.process["XDG_CONFIG_HOME"]
	if user == "" {
		user = filepath.Join(o.Home, ".config")
	}
	l.user = filepath.Join(absolutePath(user, o.CWD, o.Home), "net-connector")
	dirs := append([]string{}, o.Directories...)
	if o.Directories == nil {
		program := o.Program
		if program == "" {
			program = os.Args[0]
		}
		dirs = []string{"/etc/net-connector", "/usr/local/etc/net-connector", l.user, filepath.Dir(absolutePath(program, o.CWD, o.Home)), o.CWD}
	}
	for i, d := range dirs {
		if err := l.ctx.Err(); err != nil {
			return err
		}
		dirs[i] = absolutePath(d, o.CWD, o.Home)
	}
	l.dirs = uniquePaths(dirs, "")
	if o.EnvFile != "" {
		l.envFile = absolutePath(o.EnvFile, o.CWD, o.Home)
	}
	return nil
}

// readEnvironmentFiles reads the .env file of every search directory, the
// selected one last, recording where each variable came from.
func (l *loader) readEnvironmentFiles() error {
	candidates := []string{}
	for _, dir := range l.dirs {
		candidates = append(candidates, filepath.Join(dir, ".env"))
	}
	for _, path := range uniquePaths(candidates, l.envFile) {
		b, ok, e := ReadFile(l.ctx, path, path != l.envFile || l.o.AllowMissing)
		if e != nil {
			return e
		}
		if !ok {
			continue
		}
		m, e := ParseEnvironment(string(b), l.s.environment, l.process)
		if err := l.ctx.Err(); err != nil {
			return err
		}
		if e != nil {
			return e
		}
		if e = resolveEnvironmentPaths(m, filepath.Dir(path), l.o.Home); e != nil {
			return e
		}
		for k, v := range m {
			l.s.environment[k] = v
			l.envOrigins[k] = path
		}
		l.s.envFiles = append(l.s.envFiles, path)
	}
	return nil
}

// readConfigurationFiles selects the configuration file (explicit, then
// NC_CONFIG from the process, then from .env) and merges every
// net-connector.yml of the search directories, the selected one last.
func (l *loader) readConfigurationFiles() error {
	selected := l.o.ConfigFile
	if selected == "" {
		selected = l.process["NC_CONFIG"]
		if strings.TrimSpace(selected) == "" {
			selected = l.s.environment["NC_CONFIG"]
		}
	}
	if selected != "" {
		selected = absolutePath(selected, l.o.CWD, l.o.Home)
	}
	l.selected = selected
	paths := []string{}
	for _, dir := range l.dirs {
		paths = append(paths, filepath.Join(dir, "net-connector.yml"))
	}
	for _, path := range uniquePaths(paths, selected) {
		b, ok, e := ReadFile(l.ctx, path, path != selected || l.o.AllowMissing)
		if e != nil {
			return e
		}
		if !ok {
			continue
		}
		m, e := ParseYAML(b)
		if err := l.ctx.Err(); err != nil {
			return err
		}
		if e != nil {
			return e
		}
		if e = l.applyFile(m, path); e != nil {
			return e
		}
		l.s.applicable = true
		l.s.files = append(l.s.files, path)
	}
	return nil
}

// applyFile merges one configuration file, resolving its paths against its
// directory and recording each field's source.
func (l *loader) applyFile(m map[string]any, source string) error {
	if err := l.ctx.Err(); err != nil {
		return err
	}
	if e := resolvePaths(m, filepath.Dir(source), l.o.Home, ""); e != nil {
		return e
	}
	recordFields(l.s.fields, l.s.data, m, source, "")
	mergeValues(l.s.data, m)
	return l.ctx.Err()
}

// mergeLayers rebuilds the data by precedence: defaults, then .env values,
// then the configuration files, then the process environment. Higher layers
// mask invalid lower values before environment decoding.
func (l *loader) mergeLayers() error {
	s := l.s
	l.yamlData = s.data
	processPresence := map[string]any{}
	for path, f := range schema {
		if _, ok := l.process[f.Env]; ok {
			setPath(processPresence, path, true)
		}
	}
	s.data = map[string]any{}
	mergeValues(s.data, l.o.Defaults)
	if e := resolvePaths(s.data, l.o.CWD, l.o.Home, ""); e != nil {
		return e
	}
	defaultFields := map[string]string{}
	recordFields(defaultFields, map[string]any{}, s.data, "default", "")
	for key, source := range defaultFields {
		if _, exists := s.fields[key]; !exists {
			s.fields[key] = source
		}
	}
	for _, layer := range []struct {
		env    map[string]string
		higher map[string]any
		source string
	}{{s.environment, mergeMaps(mergeMaps(l.yamlData, processPresence), l.o.Overrides), ".env"}, {l.process, l.o.Overrides, "environment"}} {
		if err := l.ctx.Err(); err != nil {
			return err
		}
		m, e := environmentValues(layer.env, layer.higher, nil)
		if err := l.ctx.Err(); err != nil {
			return err
		}
		if e != nil {
			return e
		}
		if layer.source == ".env" {
			l.mergeDotEnv(m)
		} else {
			recordFields(s.fields, s.data, m, layer.source, "")
			mergeValues(s.data, m)
		}
	}
	return l.ctx.Err()
}

// mergeDotEnv merges the .env layer below the configuration files, recording
// the .env file each decoded field came from.
func (l *loader) mergeDotEnv(m map[string]any) {
	s := l.s
	for path, f := range schema {
		if origin := l.envOrigins[f.Env]; origin != "" && hasPath(m, path) {
			part := map[string]any{}
			setPath(part, path, valueAtPath(m, path))
			recordFields(s.fields, s.data, part, origin, "")
		}
	}
	mergeValues(s.data, m)
	mergeValues(s.data, l.yamlData)
}

// finish applies the command-line overrides, validates the merged data and
// environment against their budgets and records the selected paths.
func (l *loader) finish() error {
	s := l.s
	if overrides := cloneValue(l.o.Overrides); overrides != nil {
		m, _ := overrides.(map[string]any)
		if e := resolvePaths(m, l.o.CWD, l.o.Home, ""); e != nil {
			return e
		}
		recordFields(s.fields, s.data, m, "cli", "")
		mergeValues(s.data, m)
	}
	// Layer merging can exceed a budget even when each layer fits independently.
	if _, e := copyPlain(s.data); e != nil {
		return e
	}
	if e := validateValues(s.data); e != nil {
		return e
	}
	maps.Copy(s.environment, l.process)
	if _, e := environmentSize(s.environment); e != nil {
		return e
	}
	s.configPath = l.selected
	if s.configPath == "" {
		s.configPath = filepath.Join(l.user, "net-connector.yml")
	}
	s.envPath = l.envFile
	if s.envPath == "" {
		s.envPath = filepath.Join(l.user, ".env")
	}
	return nil
}

func hasPath(values map[string]any, path string) bool {
	parts := strings.SplitN(path, ".", 2)
	v, ok := values[parts[0]]
	if !ok {
		return false
	}
	if len(parts) == 1 {
		return true
	}
	child, ok := v.(map[string]any)
	if !ok {
		return true
	}
	return hasPath(child, parts[1])
}
func setPath(values map[string]any, path string, value any) {
	parts := strings.SplitN(path, ".", 2)
	if len(parts) == 1 {
		values[path] = value
		return
	}
	child, ok := values[parts[0]].(map[string]any)
	if !ok {
		child = map[string]any{}
		values[parts[0]] = child
	}
	setPath(child, parts[1], value)
}
func mergeMaps(base, overrides map[string]any) map[string]any {
	m := map[string]any{}
	mergeValues(m, base)
	mergeValues(m, overrides)
	return m
}
func decodeJSON(s string) (any, error) {
	var v any
	d := json.NewDecoder(strings.NewReader(s))
	if d.Decode(&v) != nil {
		return nil, ErrInvalid
	}
	var trailing any
	if d.Decode(&trailing) != io.EOF {
		return nil, ErrInvalid
	}
	return v, nil
}

// validateValues checks every section and field against the schema.
func validateValues(values map[string]any) error {
	for section, v := range values {
		fields, ok := v.(map[string]any)
		if !ok {
			return ErrInvalid
		}
		known := false
		for path := range schema {
			if strings.HasPrefix(path, section+".") {
				known = true
				break
			}
		}
		if !known {
			return ErrInvalid
		}
		for key, v := range fields {
			f, ok := schema[section+"."+key]
			if !ok {
				return ErrInvalid
			}
			valid, err := validField(section, key, f, v)
			if err != nil {
				return err
			}
			if !valid {
				return ErrInvalid
			}
		}
	}
	return nil
}

// validField reports whether v is a valid value of field section.key; an
// invalid success policy is a FieldError.
func validField(section, key string, f Field, v any) (bool, error) {
	switch f.Kind {
	case KindString, KindOptionalString:
		s, ok := v.(string)
		if section == "backup" && key == "success_policy" && !batchreport.SuccessPolicy(s).Valid() {
			return false, &FieldError{Field: "backup.success_policy", Problem: "invalid"}
		}
		return ok && (f.Kind == KindOptionalString || strings.TrimSpace(s) != ""), nil
	case KindInteger, KindOptionalInteger:
		n, ok := integerValue(v)
		zeroAllowed := section == "backup" && key == "limit_per_platform" || section == "ssh" && key == "connect_retries"
		return ok && (n > 0 || n == 0 && zeroAllowed) || v == nil && f.Kind == KindOptionalInteger, nil
	case KindNumber:
		n, ok := v.(float64)
		if i, iok := integerValue(v); iok {
			n = float64(i)
			ok = true
		}
		return ok && n > 0 && !math.IsInf(n, 0) && !math.IsNaN(n), nil
	case KindBoolean:
		_, ok := v.(bool)
		return ok, nil
	case KindList:
		a, ok := v.([]any)
		for _, item := range a {
			s, isString := item.(string)
			ok = ok && isString && strings.TrimSpace(s) != "" && !strings.Contains(s, ",")
		}
		return ok, nil
	case KindJSON, KindJSONArray:
		if f.Kind == KindJSONArray || key == "device_rules" {
			_, ok := v.([]any)
			return ok, nil
		}
		_, ok := v.(map[string]any)
		return ok, nil
	}
	return false, nil
}
func recordFields(fields map[string]string, previous, current map[string]any, source, prefix string) {
	for key, v := range current {
		name := prefix + "/" + strings.ReplaceAll(strings.ReplaceAll(key, "~", "~0"), "/", "~1")
		before, _ := previous[key].(map[string]any)
		if child, ok := v.(map[string]any); ok && len(child) > 0 {
			delete(fields, name)
			recordFields(fields, before, child, source, name)
		} else if child, ok := v.(map[string]any); ok && len(child) == 0 && len(before) > 0 {
			continue
		} else {
			for k := range fields {
				if strings.HasPrefix(k, name+"/") {
					delete(fields, k)
				}
			}
			fields[name] = source
		}
	}
}

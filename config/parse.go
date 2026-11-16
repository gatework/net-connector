// Package config loads immutable public policy and separate credential snapshots.
package config

import (
	"bytes"
	"errors"
	"io"
	"math"
	"reflect"
	"strconv"
	"strings"
	"unicode"

	"go.yaml.in/yaml/v3"
)

// ErrInvalid identifies a malformed or unsafe configuration.
var ErrInvalid = errors.New("config: invalid configuration")

// MaxBytes bounds configuration documents and expanded environment snapshots.
const MaxBytes = 16 << 20

const maxDepth = 128
const maxNodes = 100000

// ParseYAML decodes one bounded YAML mapping and rejects aliases and duplicate keys.
func ParseYAML(data []byte) (map[string]any, error) {
	return parseYAML(data, false)
}

// ParseYAMLMapping requires an explicit root mapping, including an empty {}.
// Empty documents and root nulls are invalid. All other YAML restrictions and
// resource budgets are shared with ParseYAML.
func ParseYAMLMapping(data []byte) (map[string]any, error) {
	return parseYAML(data, true)
}

func parseYAML(data []byte, requireMapping bool) (map[string]any, error) {
	if len(data) > MaxBytes {
		return nil, ErrInvalid
	}
	dec := yaml.NewDecoder(bytes.NewReader(data))
	var root yaml.Node
	if e := dec.Decode(&root); e != nil {
		if errors.Is(e, io.EOF) && !requireMapping {
			return map[string]any{}, nil
		}
		return nil, ErrInvalid
	}
	var extra yaml.Node
	if e := dec.Decode(&extra); !errors.Is(e, io.EOF) {
		return nil, ErrInvalid
	}
	y := &yamlTree{remaining: maxNodes}
	v, e := y.node(&root, 0)
	if e != nil {
		return nil, e
	}
	if v == nil && !requireMapping {
		return map[string]any{}, nil
	}
	m, ok := v.(map[string]any)
	if !ok {
		return nil, ErrInvalid
	}
	return m, nil
}
func validEnvironmentKey(key string) bool {
	if key == "" {
		return false
	}
	for i, c := range key {
		if !(c == '_' || c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || i > 0 && c >= '0' && c <= '9') {
			return false
		}
	}
	return true
}

// ParseEnvironment never executes shell syntax or consults the process environment.
// ParseEnvironment parses a .env document. Values may be quoted, and
// unquoted or double-quoted values expand $NAME and ${NAME} from process,
// then earlier entries, then inherited. The expanded environment stays
// within MaxBytes; command substitution is rejected.
func ParseEnvironment(text string, inherited, process map[string]string) (map[string]string, error) {
	if len(text) > MaxBytes {
		return nil, ErrInvalid
	}
	total, err := environmentSize(inherited)
	if err != nil {
		return nil, err
	}
	p := &envParser{text: strings.ReplaceAll(text, "\r\n", "\n"), inherited: inherited, process: process, local: map[string]string{}, total: total}
	for {
		more, err := p.entry()
		if err != nil {
			return nil, err
		}
		if !more {
			return p.local, nil
		}
	}
}

// envParser is the state of one ParseEnvironment call.
type envParser struct {
	text                      string // the unparsed rest of the document
	inherited, process, local map[string]string
	total                     int // bytes of the effective environment so far
}

// lookup resolves a variable: the process first, then earlier entries,
// then the inherited environment.
func (p *envParser) lookup(k string) string {
	if v, ok := p.process[k]; ok {
		return v
	}
	if v, ok := p.local[k]; ok {
		return v
	}
	return p.inherited[k]
}

// entry parses one assignment; more is false at the end of the document.
func (p *envParser) entry() (more bool, err error) {
	for {
		p.text = strings.TrimLeft(p.text, " \t\r\n")
		if p.text == "" {
			return false, nil
		}
		if p.text[0] != '#' {
			break
		}
		_, p.text, _ = strings.Cut(p.text, "\n")
	}
	if strings.HasPrefix(p.text, "export ") {
		p.text = strings.TrimLeft(p.text[7:], " \t")
	}
	equal := strings.IndexByte(p.text, '=')
	if equal < 0 || strings.Contains(p.text[:equal], "\n") {
		return false, ErrInvalid
	}
	key := strings.TrimSpace(p.text[:equal])
	if !validEnvironmentKey(key) {
		return false, ErrInvalid
	}
	p.text = strings.TrimLeft(p.text[equal+1:], " \t")
	quote := byte(0)
	if len(p.text) > 0 && (p.text[0] == '\'' || p.text[0] == '"') {
		quote = p.text[0]
		p.text = p.text[1:]
	}
	// Reserve the effective snapshot's other entries before expanding this value.
	base := p.total
	if old, ok := p.local[key]; ok {
		base -= len(key) + len(old)
	} else if old, ok := p.inherited[key]; ok {
		base -= len(key) + len(old)
	}
	if len(key) > MaxBytes-base {
		return false, ErrInvalid
	}
	base += len(key)
	value, err := p.value(quote, base)
	if err != nil {
		return false, err
	}
	p.local[key] = value
	p.total = base + len(value)
	return true, nil
}

// value reads one value up to its closing quote or the end of the line and
// expands variables outside single quotes.
func (p *envParser) value(quote byte, base int) (string, error) {
	v := boundedValue{base: base}
	closed := quote == 0
	for len(p.text) > 0 {
		c := p.text[0]
		p.text = p.text[1:]
		if quote != 0 && c == quote {
			closed = true
			break
		}
		if quote == 0 && (c == '\n' || c == '#') {
			if c == '#' {
				_, p.text, _ = strings.Cut(p.text, "\n")
			}
			break
		}
		if err := p.valueByte(&v, quote, c); err != nil {
			return "", err
		}
	}
	if !closed {
		return "", ErrInvalid
	}
	value := v.String()
	if quote == 0 {
		value = strings.TrimRightFunc(value, unicode.IsSpace)
	} else {
		line, rest, _ := strings.Cut(p.text, "\n")
		if tail := strings.TrimSpace(line); tail != "" && !strings.HasPrefix(tail, "#") {
			return "", ErrInvalid
		}
		p.text = rest
	}
	if strings.IndexByte(value, 0) >= 0 {
		return "", ErrInvalid
	}
	return value, nil
}

func (p *envParser) valueByte(v *boundedValue, quote, c byte) error {
	if c == '\\' && quote != '\'' && len(p.text) > 0 && strings.IndexByte("$\"\\# ", p.text[0]) >= 0 {
		if err := v.writeByte(p.text[0]); err != nil {
			return err
		}
		p.text = p.text[1:]
		return nil
	}
	if c == '$' && quote != '\'' {
		name, err := p.variable()
		if err != nil {
			return err
		}
		if name != "" {
			return v.write(p.lookup(name))
		}
	}
	return v.writeByte(c)
}

// variable reads the name after a $: ${NAME} or a bare identifier. A bare
// $ yields "", and command substitution $( is rejected.
func (p *envParser) variable() (string, error) {
	if strings.HasPrefix(p.text, "(") {
		return "", ErrInvalid
	}
	if strings.HasPrefix(p.text, "{") {
		end := strings.IndexByte(p.text, '}')
		if end < 0 {
			return "", ErrInvalid
		}
		name := p.text[1:end]
		p.text = p.text[end+1:]
		if !validEnvironmentKey(name) {
			return "", ErrInvalid
		}
		return name, nil
	}
	n := 0
	for n < len(p.text) && (p.text[n] == '_' || p.text[n] >= 'A' && p.text[n] <= 'Z' || p.text[n] >= 'a' && p.text[n] <= 'z' || n > 0 && p.text[n] >= '0' && p.text[n] <= '9') {
		n++
	}
	name := p.text[:n]
	p.text = p.text[n:]
	return name, nil
}

// boundedValue builds one value within MaxBytes, counting base bytes the
// rest of the environment already uses.
type boundedValue struct {
	b    strings.Builder
	base int
}

func (v *boundedValue) String() string { return v.b.String() }

func (v *boundedValue) write(s string) error {
	if len(s) > MaxBytes-v.b.Len() || len(s) > MaxBytes-v.base-v.b.Len() {
		return ErrInvalid
	}
	v.b.WriteString(s)
	return nil
}

func (v *boundedValue) writeByte(c byte) error {
	if v.b.Len() >= MaxBytes || v.b.Len() >= MaxBytes-v.base {
		return ErrInvalid
	}
	v.b.WriteByte(c)
	return nil
}

// environmentSize bounds an effective environment snapshot, including key bytes.
func environmentSize(values map[string]string) (int, error) {
	total := 0
	for key, value := range values {
		if len(key) > MaxBytes-total {
			return 0, ErrInvalid
		}
		total += len(key)
		if len(value) > MaxBytes-total {
			return 0, ErrInvalid
		}
		total += len(value)
	}
	return total, nil
}

// copyPlain owns canonical maps and slices and rejects opaque mutable values.
// copyPlain deep-copies a plain YAML/JSON value within the node, byte and
// depth budgets, rejecting cycles, non-finite numbers and other types.
func copyPlain(v any) (any, error) {
	c := &plainCopy{nodes: maxNodes, bytes: MaxBytes, active: map[uintptr]bool{}}
	return c.value(v, 0)
}

// plainCopy is the budget state of one copyPlain call.
type plainCopy struct {
	nodes, bytes int
	active       map[uintptr]bool // containers on the current path
}

func (c *plainCopy) value(v any, depth int) (any, error) {
	c.nodes--
	if depth > maxDepth || c.nodes < 0 {
		return nil, ErrInvalid
	}
	switch x := v.(type) {
	case map[string]any:
		return c.mapping(x, depth)
	case []any:
		return c.list(x, depth)
	case string:
		if len(x) > c.bytes {
			return nil, ErrInvalid
		}
		c.bytes -= len(x)
		return x, nil
	case nil, bool, int, int8, int16, int32, int64, uint, uint8, uint16, uint32, uint64:
		return v, nil
	case float64:
		if math.IsNaN(x) || math.IsInf(x, 0) {
			return nil, ErrInvalid
		}
		return x, nil
	default:
		return nil, ErrInvalid
	}
}

func (c *plainCopy) mapping(x map[string]any, depth int) (any, error) {
	id := uintptr(reflect.ValueOf(x).UnsafePointer())
	if c.active[id] || len(x) > c.nodes/2 {
		return nil, ErrInvalid
	}
	c.active[id] = true
	defer delete(c.active, id)
	m := make(map[string]any, len(x))
	for k, item := range x {
		c.nodes--
		if c.nodes < 0 || len(k) > c.bytes {
			return nil, ErrInvalid
		}
		c.bytes -= len(k)
		v, e := c.value(item, depth+1)
		if e != nil {
			return nil, e
		}
		m[k] = v
	}
	return m, nil
}

func (c *plainCopy) list(x []any, depth int) (any, error) {
	id := reflect.ValueOf(x).Pointer()
	if len(x) > c.nodes || (len(x) > 0 && c.active[id]) {
		return nil, ErrInvalid
	}
	if len(x) > 0 {
		c.active[id] = true
		defer delete(c.active, id)
	}
	a := make([]any, len(x))
	for i, item := range x {
		v, e := c.value(item, depth+1)
		if e != nil {
			return nil, e
		}
		a[i] = v
	}
	return a, nil
}

// cloneValue is only used after inputs and the complete snapshot passed copyPlain.
func cloneValue(v any) any {
	value, _ := copyPlain(v)
	return value
}
func mergeValues(destination, source map[string]any) {
	for key, value := range source {
		existing, existingIsMap := destination[key].(map[string]any)
		incoming, incomingIsMap := value.(map[string]any)
		if existingIsMap && incomingIsMap {
			mergeValues(existing, incoming)
		} else {
			destination[key] = cloneValue(value)
		}
	}
}
func integerValue(value any) (int, bool) {
	switch n := value.(type) {
	case int:
		return n, true
	case int8:
		return int(n), true
	case int16:
		return int(n), true
	case int32:
		return int(n), true
	case int64:
		if n >= math.MinInt && n <= math.MaxInt {
			return int(n), true
		}
	case uint:
		if n <= math.MaxInt {
			return int(n), true
		}
	case uint8:
		return int(n), true
	case uint16:
		return int(n), true
	case uint32:
		if uint64(n) <= uint64(math.MaxInt) {
			return int(n), true
		}
	case uint64:
		if n <= uint64(math.MaxInt) {
			return int(n), true
		}
	}
	return 0, false
}
func decodeEnv(s string, kind FieldKind) (any, error) {
	switch kind {
	case KindInteger, KindOptionalInteger:
		n, e := strconv.Atoi(s)
		return n, e
	case KindNumber:
		n, e := strconv.ParseFloat(s, 64)
		return n, e
	case KindBoolean:
		if s != "true" && s != "false" {
			return nil, ErrInvalid
		}
		return s == "true", nil
	case KindList:
		a := []any{}
		if s == "" {
			return a, nil
		}
		for v := range strings.SplitSeq(s, ",") {
			a = append(a, strings.TrimSpace(v))
		}
		return a, nil
	case KindJSON, KindJSONArray:
		return decodeJSON(s)
	case KindString, KindOptionalString:
		return s, nil
	default:
		return s, nil
	}
}

// yamlTree converts a YAML node tree into plain values within the node and
// depth budgets; anchors, aliases, custom tags and duplicate keys are rejected.
type yamlTree struct {
	remaining int // nodes still allowed
}

func (y *yamlTree) node(n *yaml.Node, depth int) (any, error) {
	y.remaining--
	if depth > maxDepth || y.remaining < 0 || n.Kind == yaml.AliasNode || n.Anchor != "" {
		return nil, ErrInvalid
	}
	switch n.Kind {
	case yaml.DocumentNode:
		if len(n.Content) != 1 {
			return nil, ErrInvalid
		}
		return y.node(n.Content[0], depth+1)
	case yaml.MappingNode:
		return y.mapping(n, depth)
	case yaml.SequenceNode:
		return y.sequence(n, depth)
	case yaml.ScalarNode:
		return scalar(n)
	case yaml.AliasNode: // rejected above; aliases could expand without bound
		return nil, ErrInvalid
	}
	return nil, ErrInvalid
}

func (y *yamlTree) mapping(n *yaml.Node, depth int) (any, error) {
	if n.Tag != "!!map" {
		return nil, ErrInvalid
	}
	m := map[string]any{}
	for i := 0; i < len(n.Content); i += 2 {
		k := n.Content[i]
		y.remaining--
		if y.remaining < 0 || k.Kind != yaml.ScalarNode || k.Tag != "!!str" || k.Anchor != "" {
			return nil, ErrInvalid
		}
		if _, ok := m[k.Value]; ok {
			return nil, ErrInvalid
		}
		v, e := y.node(n.Content[i+1], depth+1)
		if e != nil {
			return nil, e
		}
		m[k.Value] = v
	}
	return m, nil
}

func (y *yamlTree) sequence(n *yaml.Node, depth int) (any, error) {
	if n.Tag != "!!seq" {
		return nil, ErrInvalid
	}
	a := make([]any, 0, len(n.Content))
	for _, c := range n.Content {
		v, e := y.node(c, depth+1)
		if e != nil {
			return nil, e
		}
		a = append(a, v)
	}
	return a, nil
}

// scalar decodes a string, null, bool, int or finite float scalar.
//
//nolint:nilnil // YAML null decodes to a nil value
func scalar(n *yaml.Node) (any, error) {
	switch n.Tag {
	case "!!str":
		return n.Value, nil
	case "!!null":
		return nil, nil
	case "!!bool":
		var v bool
		if n.Decode(&v) != nil {
			return nil, ErrInvalid
		}
		return v, nil
	case "!!int":
		var v int64
		if n.Decode(&v) != nil {
			return nil, ErrInvalid
		}
		return int(v), nil
	case "!!float":
		var v float64
		if n.Decode(&v) != nil || math.IsNaN(v) || math.IsInf(v, 0) {
			return nil, ErrInvalid
		}
		return v, nil
	}
	return nil, ErrInvalid
}

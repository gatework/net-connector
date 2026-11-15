// Package textfsm parses device output with independent, embedded TextFSM templates.
package textfsm

import (
	"bufio"
	"embed"
	"errors"
	"io/fs"
	"maps"
	"strings"
	"sync"
	"unicode/utf8"

	fsm "github.com/sirikothe/gotextfsm"

	"github.com/gatework/net-connector/internal/terminal"
)

var (
	// ErrTemplateMissing reports an unavailable template for the requested command.
	ErrTemplateMissing = errors.New("textfsm: template missing")
	// ErrTemplateInvalid reports a malformed embedded template.
	ErrTemplateInvalid = errors.New("textfsm: invalid template")
	// ErrParse reports a response that the selected template cannot parse.
	ErrParse = errors.New("textfsm: parse failed")
	// ErrEncoding reports invalid response text before parsing.
	ErrEncoding = errors.New("textfsm: invalid encoding")
	// ErrIncomplete reports a response without required completion evidence.
	ErrIncomplete = errors.New("textfsm: incomplete output")
)

//go:embed templates
var templates embed.FS

type catalog struct {
	templates map[string]func() (fsm.TextFSM, error)
}

var embeddedCatalog = sync.OnceValues(loadCatalog)

func loadCatalog() (*catalog, error) {
	c := &catalog{templates: make(map[string]func() (fsm.TextFSM, error))}
	err := fs.WalkDir(templates, "templates", func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || !strings.HasSuffix(path, ".textfsm") {
			return nil
		}
		c.templates[strings.TrimPrefix(path, "templates/")] = sync.OnceValues(func() (fsm.TextFSM, error) {
			data, err := templates.ReadFile(path)
			if err != nil {
				return fsm.TextFSM{}, ErrTemplateMissing
			}
			return compileTemplate(string(data))
		})
		return nil
	})
	if err != nil {
		return nil, ErrTemplateInvalid
	}
	return c, nil
}

// compileTemplate contains dependency panic paths at the untrusted input boundary.
func compileTemplate(source string) (machine fsm.TextFSM, err error) {
	defer func() {
		if recover() != nil {
			machine = fsm.TextFSM{}
			err = ErrTemplateInvalid
		}
	}()
	if !utf8.ValidString(source) {
		return machine, ErrEncoding
	}
	if err = machine.ParseScanner(newScanner(source)); err != nil {
		return fsm.TextFSM{}, ErrTemplateInvalid
	}
	return machine, nil
}

// ParseTemplate accepts TextFSM source or an embedded template path (for example
// cisco/show_running_config.textfsm). It does not read arbitrary filesystem paths.
// Errors deliberately discard dependency messages containing device text.
func ParseTemplate(template, output string) (rows []map[string]any, err error) {
	if !utf8.ValidString(output) {
		return nil, ErrEncoding
	}
	var machine fsm.TextFSM
	if !strings.Contains(template, "\n") && strings.HasSuffix(template, ".textfsm") {
		c, e := embeddedCatalog()
		if e != nil {
			return nil, e
		}
		load, ok := c.templates[template]
		if !ok {
			return nil, ErrTemplateMissing
		}
		machine, err = load()
	} else {
		machine, err = compileTemplate(template)
	}
	if err != nil {
		return nil, err
	}
	// gotextfsm mutates Values during parsing. The cached pristine values and
	// read-only states/regexps are never handed to its parser directly.
	machine.Values = maps.Clone(machine.Values)
	// The dependency has panic paths for malformed custom expressions; keep that
	// implementation detail from escaping this untrusted-input boundary.
	defer func() {
		if recover() != nil {
			rows = nil
			err = ErrTemplateInvalid
		}
	}()
	text, e := terminal.RenderString(output, true)
	if e != nil {
		if errors.Is(e, terminal.ErrEncoding) {
			return nil, ErrEncoding
		}
		return nil, ErrIncomplete
	}
	var parsed fsm.ParserOutput
	scanner := newScanner(text)
	if e = parsed.ParseTextScanner(scanner, machine, true); e != nil {
		if scanner.Err() != nil {
			return nil, ErrIncomplete
		}
		return nil, ErrParse
	}
	return parsed.Dict, nil
}
func newScanner(text string) *bufio.Scanner {
	s := bufio.NewScanner(strings.NewReader(text))
	s.Buffer(make([]byte, 4096), (32<<20)+1)
	return s
}

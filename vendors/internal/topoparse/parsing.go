package topoparse

import (
	"regexp"
	"strings"
	"sync"
	"unicode"

	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/topology"
)

var (
	patternCache   sync.Map
	horizontalLine = regexp.MustCompile(`^[-=+ ]+$`)
	promptLine     = regexp.MustCompile(`^(?:<[^>]+>|\[[^\]]+\])$`)
)

// Pattern compiles a family-owned parsing expression once and reuses it.
func Pattern(expression string) *regexp.Regexp {
	if cached, ok := patternCache.Load(expression); ok {
		if re, ok := cached.(*regexp.Regexp); ok {
			return re
		}
	}
	compiled := regexp.MustCompile(expression)
	actual, _ := patternCache.LoadOrStore(expression, compiled)
	re, _ := actual.(*regexp.Regexp) // the cache stores only *regexp.Regexp
	return re
}

// Field returns a text field from a TextFSM row.
func Field(row map[string]any, name string) string {
	value, _ := row[name].(string)
	return value
}

// Neighbor is a vendor-neutral adjacency parsed from device output.
type Neighbor = topology.Neighbor

// Count returns the number of matches for a family-owned record expression.
func Count(expression, text string) int {
	return len(Pattern(expression).FindAllStringIndex(text, -1))
}

// TableLines extracts nonblank rows after a recognized table header.
func TableLines(output string, header *regexp.Regexp) ([]string, bool) {
	seen := false
	lines := []string{}
	for line := range strings.SplitSeq(output, "\n") {
		if header.MatchString(line) {
			seen = true
			continue
		}
		if !seen {
			continue
		}
		line = strings.TrimSpace(line)
		if line == "" || horizontalLine.MatchString(line) || promptLine.MatchString(line) {
			continue
		}
		lines = append(lines, line)
	}
	return lines, seen
}

// DecodeQuoted decodes device configuration words while preserving quoted spaces.
func DecodeQuoted(value string, split bool) (string, error) {
	value = strings.TrimSpace(value)
	if !split && !strings.HasPrefix(value, `"`) {
		return value, nil
	}
	words := []string{}
	var word strings.Builder
	var quote rune
	started, escape := false, false
	for _, r := range value {
		if escape {
			writeEscapedRune(&word, quote, r)
			escape = false
			started = true
			continue
		}
		if r == '\\' && quote != '\'' {
			escape = true
			started = true
			continue
		}
		if quote != 0 {
			if r == quote {
				quote = 0
			} else {
				word.WriteRune(r)
			}
			continue
		}
		if r == '"' || r == '\'' {
			quote = r
			started = true
			continue
		}
		if unicode.IsSpace(r) {
			if started {
				words = append(words, word.String())
				word.Reset()
				started = false
			}
			continue
		}
		word.WriteRune(r)
		started = true
	}
	if quote != 0 || escape {
		return "", platform.ErrParse
	}
	if started {
		words = append(words, word.String())
	}
	return strings.Join(words, " "), nil
}

func writeEscapedRune(word *strings.Builder, quote, r rune) {
	if quote == '"' && r != '"' && r != '\\' && r != '$' && r != '`' && r != '\n' {
		word.WriteRune('\\')
	}
	if r != '\n' {
		word.WriteRune(r)
	}
}

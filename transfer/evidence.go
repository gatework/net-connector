package transfer

import (
	"errors"
	"regexp"
	"strings"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/internal/terminal"
)

const maxEvidenceLines = 1 << 16

var errEvidenceLimit = errors.New("transfer: completion evidence exceeds line limit")

func isASCIIWordByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_'
}

type evidenceStep struct {
	command connector.Command
	prompt  string
	output  string
}

type evidencePredicate func(connector.Command, string, string) bool

func evidenceLines(command connector.Command, responsePrompt, output string) ([]string, error) {
	count := 0
	withinLimit := true
	forEachEvidenceLine(command, responsePrompt, output, func(string) bool {
		count++
		withinLimit = count <= maxEvidenceLines
		return withinLimit
	})
	if !withinLimit {
		return nil, errEvidenceLimit
	}
	out := make([]string, 0, count)
	forEachEvidenceLine(command, responsePrompt, output, func(line string) bool {
		out = append(out, line)
		return true
	})
	return out, nil
}

func forEachEvidenceLine(command connector.Command, responsePrompt, output string, visit func(string) bool) {
	echoes := evidenceEchoes(command, responsePrompt)
	for len(output) > 0 {
		end := strings.IndexAny(output, "\r\n")
		line := output
		if end >= 0 {
			line, output = output[:end], output[end+1:]
			for len(output) > 0 && (output[0] == '\r' || output[0] == '\n') {
				output = output[1:]
			}
		} else {
			output = ""
		}
		line = normalizeEvidenceLine(line)
		if line != "" && !echoes[line] && !visit(line) {
			return
		}
	}
}

func evidenceEchoes(command connector.Command, responsePrompt string) map[string]bool {
	prompt := strings.TrimSpace(responsePrompt)
	echoes := map[string]bool{command.Text: true, prompt + command.Text: true, prompt: true}
	for _, reply := range command.Interactions {
		if reply.Respond == nil {
			echoes[strings.TrimSuffix(reply.Reply, "\n")] = true
		}
	}
	return echoes
}

func matchesEvidencePattern(command connector.Command, responsePrompt, output string, expression *regexp.Regexp) bool {
	echoes := evidenceEchoes(command, responsePrompt)
	text := stripSGR(output)
	for offset := 0; offset < len(text); {
		match := expression.FindStringIndex(text[offset:])
		if match == nil {
			return false
		}
		start, end := offset+match[0], offset+match[1]
		lineStart := start
		for lineStart < len(text) && (text[lineStart] == '\r' || text[lineStart] == '\n') {
			lineStart++
		}
		if previous := strings.LastIndexAny(text[:lineStart], "\r\n"); previous >= 0 {
			lineStart = previous + 1
		}
		lineEnd := len(text)
		if next := strings.IndexAny(text[lineStart:], "\r\n"); next >= 0 {
			lineEnd = lineStart + next
		}
		line := strings.TrimSpace(text[lineStart:lineEnd])
		if !echoes[line] {
			return true
		}
		if lineEnd == len(text) {
			return false
		}
		offset = lineEnd + 1
		if text[lineEnd] == '\r' && offset < len(text) && text[offset] == '\n' {
			offset++
		}
		if offset <= start || offset <= end {
			continue
		}
	}
	return false
}

func failed(command connector.Command, responsePrompt, output string) bool {
	echoes := evidenceEchoes(command, responsePrompt)
	text := stripSGR(output)
	for start := 0; start < len(text); start++ {
		length := failureLengthAt(text, start)
		if length == 0 {
			continue
		}
		if start > 0 && (isASCIIWordByte(text[start-1]) || isBoundaryPunctuation(text[start-1])) {
			continue
		}
		end := start + length
		if end < len(text) && (isASCIIWordByte(text[end]) || text[end] == '/' || text[end] == '-' || text[end] == '.' && end+1 < len(text) && isASCIIWordByte(text[end+1])) {
			continue
		}
		lineStart, lineEnd := evidenceLineBounds(text, start)
		if echoes[strings.TrimSpace(text[lineStart:lineEnd])] {
			start = nextEvidenceLine(text, lineEnd) - 1
			continue
		}
		return true
	}
	return false
}

func failureLengthAt(text string, start int) int {
	if start >= len(text) {
		return 0
	}
	switch lowerASCIIByte(text[start]) {
	case 'a':
		if equalFoldASCII(text[start:], "aborted") {
			return len("aborted")
		}
	case 'c':
		if equalFoldASCII(text[start:], "can't open") {
			return len("can't open")
		}
	case 'd':
		if equalFoldASCII(text[start:], "denied") {
			return len("denied")
		}
	case 'e':
		if equalFoldASCII(text[start:], "error") {
			return len("error")
		}
	case 'f':
		if equalFoldASCII(text[start:], "failed") {
			return len("failed")
		}
		if equalFoldASCII(text[start:], "failure") {
			return len("failure")
		}
	case 'n':
		if equalFoldASCII(text[start:], "network is unreachable") {
			return len("network is unreachable")
		}
		if equalFoldASCII(text[start:], "not found") {
			return len("not found")
		}
		if equalFoldASCII(text[start:], "no such file") {
			return len("no such file")
		}
	case 't':
		if equalFoldASCII(text[start:], "timed out") {
			return len("timed out")
		}
		if equalFoldASCII(text[start:], "timeout") {
			return len("timeout")
		}
	case 'u':
		if equalFoldASCII(text[start:], "unable to") {
			return len("unable to")
		}
	}
	return 0
}

func lowerASCIIByte(c byte) byte {
	if c >= 'A' && c <= 'Z' {
		return c + ('a' - 'A')
	}
	return c
}

func equalFoldASCII(text, lower string) bool {
	if len(text) < len(lower) {
		return false
	}
	for i := range lower {
		if lowerASCIIByte(text[i]) != lower[i] {
			return false
		}
	}
	return true
}

func isBoundaryPunctuation(c byte) bool { return c == '.' || c == '/' || c == '-' }

func evidenceLineBounds(text string, at int) (start, end int) {
	start = strings.LastIndexAny(text[:at], "\r\n") + 1
	end = len(text)
	if next := strings.IndexAny(text[at:], "\r\n"); next >= 0 {
		end = at + next
	}
	return start, end
}

func nextEvidenceLine(text string, end int) int {
	end++
	if text[end-1] == '\r' && end < len(text) && text[end] == '\n' {
		end++
	}
	return end
}

func normalizeEvidenceLine(line string) string {
	return strings.TrimSpace(stripSGR(line))
}

func stripSGR(input string) string {
	first := strings.IndexByte(input, 27)
	if first < 0 {
		return input
	}
	var output strings.Builder
	output.Grow(len(input))
	output.WriteString(input[:first])
	for i := first; i < len(input); {
		if input[i] == 27 && i+1 < len(input) && input[i+1] == '[' {
			end := i + 2
			for end < len(input) && (input[end] >= '0' && input[end] <= '9' || input[end] == ';' || input[end] == ':') {
				end++
			}
			if end < len(input) && input[end] == 'm' {
				i = end + 1
				continue
			}
		}
		output.WriteByte(input[i])
		i++
	}
	return output.String()
}

func inspectTransferEvidence(steps []connector.StepResult, rejected evidencePredicate) (lines []string, failureDetected bool, err error) {
	inputs := make([]evidenceStep, len(steps))
	for i, step := range steps {
		prompt, e := step.Response().Prompt()
		if e != nil {
			return nil, false, e
		}
		output, e := step.Response().Output()
		if e != nil {
			return nil, false, e
		}
		inputs[i] = evidenceStep{command: step.Command(), prompt: prompt, output: output}
	}
	return collectEvidence(inputs, rejected)
}

func collectEvidence(steps []evidenceStep, rejected evidencePredicate) (lines []string, failureDetected bool, err error) {
	for i, step := range steps {
		rendered, e := renderEvidence(step.output)
		if e != nil {
			return nil, false, e
		}
		if rejected != nil && (rejected(step.command, step.prompt, step.output) || rejected(step.command, step.prompt, rendered)) {
			return nil, true, nil
		}
		if i == len(steps)-1 {
			if step.prompt != "" {
				rendered = strings.TrimSuffix(rendered, step.prompt)
			}
			lines, e = evidenceLines(step.command, step.prompt, rendered)
			if e != nil {
				return nil, false, e
			}
		}
	}
	return lines, false, nil
}

func renderEvidence(input string) (string, error) {
	var output strings.Builder
	renderer := terminal.New(&output, 32<<20, true)
	var buffer [32 << 10]byte
	for len(input) > 0 {
		n := copy(buffer[:], input)
		if _, err := renderer.Write(buffer[:n]); err != nil {
			return "", err
		}
		input = input[n:]
	}
	if err := renderer.Finish(); err != nil {
		return "", err
	}
	return output.String(), nil
}

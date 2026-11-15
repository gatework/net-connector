package topoparse

import (
	"slices"
	"strings"

	"github.com/gatework/net-connector/platform"
)

func validateInterfaceRows(text string, rows []map[string]any) error {
	expected := []string{}
	for _, match := range Pattern(`(?m)^interface[ \t]+([^\r\n]*)`).FindAllStringSubmatch(text, -1) {
		expected = append(expected, strings.TrimSpace(match[1]))
	}
	actual := make([]string, 0, len(rows))
	for _, row := range rows {
		actual = append(actual, strings.TrimSpace(Field(row, "INTERFACE")))
	}
	if !slices.Equal(expected, actual) {
		return platform.ErrParse
	}
	return nil
}

// ValidateInterfaceRows ensures parsed interface blocks match source config order.
func ValidateInterfaceRows(text string, rows []map[string]any) error {
	return validateInterfaceRows(text, rows)
}

package radware

import (
	"strings"

	expect "github.com/gatework/go-expect"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/vendors/internal/driver"
)

type configPolicy struct{ driver.BaseConfigPolicy }

var configPromptPattern = driver.Regex(`\A(>>[ \t]+(?:.* - )?)[^\r\n#]+#\z`)

func (p configPolicy) MatchPrompt(command, current string) (expect.Pattern, error) {
	prompt := strings.Trim(current, " \t\x00\r\n")
	if command == "/cfg/dump" {
		prompt = configPromptPattern.ReplaceAllString(prompt, "${1}Configuration#")
	}
	return expect.Line(prompt), nil
}

func configFactory() func() connector.ConfigStrategy {
	return func() connector.ConfigStrategy { return driver.NewConfigStrategy(configPolicy{}) }
}

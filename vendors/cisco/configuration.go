package cisco

import (
	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/vendors/internal/driver"
)

type configPolicy struct{ driver.BaseConfigPolicy }

var (
	headerPattern   = driver.Regex(`(?i)\A(?:[ \t]*\n|![^\n]*\n|(?:\S+[#])?show[ \t]+running-config[^\n]*\n|Building[ \t]+configuration[^\n]*\n|Current[ \t]+configuration[^\n]*\n)*`)
	volatilePattern = driver.Regex(`(?im)^!.*(?:Last\s+configuration\s+change|NVRAM\s+config).*\n`)
)

func (p configPolicy) Clean(_ connector.StepResult, visible, _ string) (string, error) {
	header := headerPattern.FindString(visible)
	cleaned := volatilePattern.ReplaceAllString(header, "")
	if cleaned == header {
		return visible, nil
	}
	return cleaned + visible[len(header):], nil
}

func configFactory() func() connector.ConfigStrategy {
	return func() connector.ConfigStrategy { return driver.NewConfigStrategy(configPolicy{}) }
}

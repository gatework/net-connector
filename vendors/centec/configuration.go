package centec

import (
	"strings"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/vendors/internal/driver"
)

type configPolicy struct{ driver.BaseConfigPolicy }

func (p configPolicy) Clean(_ connector.StepResult, visible, prompt string) (string, error) {
	for _, echo := range []string{"show running-config\n", prompt + "show running-config\n"} {
		visible = strings.TrimPrefix(visible, echo)
	}
	if before, ok := strings.CutSuffix(visible, prompt); ok {
		visible = before
		if !strings.HasSuffix(visible, "\n") {
			visible += "\n"
		}
	}
	return visible, nil
}

func configFactory() func() connector.ConfigStrategy {
	return func() connector.ConfigStrategy { return driver.NewConfigStrategy(configPolicy{}) }
}

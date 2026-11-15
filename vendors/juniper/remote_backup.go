package juniper

import (
	"regexp"
	"strings"
	"time"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/transfer"
	"github.com/gatework/net-connector/vendors/internal/driver"
)

type remoteBackupPolicy struct{}

var (
	remotePasswordPattern = driver.Pattern(`(?i)(?:password(?: for [^\r\n:]*)?):\s*$`)
	remoteSavedPattern    = regexp.MustCompile(`^Wrote ([1-9][0-9]*) lines of output to '([^']+)'$`)
)

func (remoteBackupPolicy) Destination(o transfer.RemoteBackupOptions) string {
	return o.Protocol + "://" + o.Username + "@" + o.Server + "/" + o.Path
}

func (p remoteBackupPolicy) Command(o transfer.RemoteBackupOptions, password string) connector.Command {
	timeout := 180 * time.Second
	command := connector.Command{
		Text:            "show configuration | save " + p.Destination(o),
		Timeout:         &timeout,
		OutputSensitive: true,
	}
	if password != "" {
		command.Interactions = []connector.Interaction{{
			Pattern:   remotePasswordPattern,
			Reply:     password + "\n",
			Sensitive: true,
			Limit:     1,
		}}
	}
	return command
}

func (remoteBackupPolicy) Completed(lines []string, destination string) bool {
	for _, line := range lines {
		match := remoteSavedPattern.FindStringSubmatch(strings.TrimSpace(line))
		if len(match) == 3 && match[2] == destination {
			return true
		}
	}
	return false
}

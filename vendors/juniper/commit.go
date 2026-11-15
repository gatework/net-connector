package juniper

import (
	"context"
	"strconv"
	"strings"
	"time"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/vendors/internal/driver"
)

var (
	// configPrompt is the Junos configuration-mode prompt, "user@host#".
	configPrompt   = driver.Pattern(`(?:\A|[\r\n])[^\s@]+@[^\s>#]+#[ \t]*\z`)
	commitComplete = driver.Regex(`^commit complete$`)
)

// commitTimeout bounds one Junos commit, which can take minutes on a large
// configuration.
const commitTimeout = 5 * time.Minute

// CommitTraits reports the Junos candidate model: an exclusive candidate is
// discarded when its session ends, and commits can be confirmed.
func (Platform) CommitTraits() connector.CommitTraits {
	return connector.CommitTraits{ConfirmSupported: true}
}

// CandidateScript wraps body in an exclusive configuration session. The
// candidate is checked before it is committed. With ConfirmMinutes the first
// commit rolls back automatically unless the second one confirms it.
func (Platform) CandidateScript(body connector.Script, o connector.CommitOptions) (connector.Script, error) {
	commits := []connector.Command{driver.CommitCommand("commit", commitTimeout)}
	if o.ConfirmMinutes > 0 {
		commits = []connector.Command{
			driver.CommitCommand("commit confirmed "+strconv.Itoa(o.ConfirmMinutes), commitTimeout),
			driver.CommitCommand("commit", commitTimeout),
		}
	}
	steps := driver.CandidateSteps{Enter: "configure exclusive", Check: "commit check", Commit: commits, Leave: "exit", Prompt: configPrompt}
	return steps.CandidateScript(body), nil
}

// ValidateCommit requires "commit complete" from every commit command.
func (Platform) ValidateCommit(ctx context.Context, result connector.Result) error {
	isCommit := func(text string) bool { return text == "commit" || strings.HasPrefix(text, "commit confirmed ") }
	return driver.ValidateCommit(ctx, result, isCommit, commitComplete)
}

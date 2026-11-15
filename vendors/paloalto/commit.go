package paloalto

import (
	"context"
	"time"

	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/vendors/internal/driver"
)

var commitSucceeded = driver.Regex(`^Configuration committed successfully$`)

// commitTimeout bounds one PAN-OS commit job.
const commitTimeout = 10 * time.Minute

// CommitTraits reports the PAN-OS candidate model: the candidate is shared and
// outlives the session, and there is no confirmed commit.
func (Platform) CommitTraits() connector.CommitTraits {
	return connector.CommitTraits{CandidateShared: true}
}

// CandidateScript wraps body in configuration mode followed by one commit.
func (Platform) CandidateScript(body connector.Script, _ connector.CommitOptions) (connector.Script, error) {
	steps := driver.CandidateSteps{Enter: "configure", Commit: []connector.Command{driver.CommitCommand("commit", commitTimeout)}, Leave: "exit"}
	return steps.CandidateScript(body), nil
}

// ValidateCommit requires "Configuration committed successfully".
func (Platform) ValidateCommit(ctx context.Context, result connector.Result) error {
	return driver.ValidateCommit(ctx, result, func(text string) bool { return text == "commit" }, commitSucceeded)
}

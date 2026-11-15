package cli

import (
	"errors"
	"strings"
	"testing"

	"github.com/gatework/net-connector/internal/workflow"
)

func TestTFTPArchivePreflightDiagnostic(t *testing.T) {
	r, _, out := fixtureRuntime(t)
	code := r.fail("netman", errors.Join(workflow.ErrTFTPArchivePreflight, errors.New("PRIVATE_PASSWORD")))
	if code != 2 || !strings.Contains(out.String(), "归档预检失败") || !strings.Contains(out.String(), "tftp-archive") || strings.Contains(out.String(), "PRIVATE") {
		t.Fatal(code, out.String())
	}
}

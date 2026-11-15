package cli

import (
	"bytes"
	"strings"
	"testing"
)

func TestVersionRemainsPureAndReportsBuildIdentity(t *testing.T) {
	var output bytes.Buffer
	r := Runtime{Args: []string{"--config", "/does/not/exist", "--version"}, Input: panicReader{}, Output: &output, Error: &bytes.Buffer{}}
	if code := r.Run(t.Context()); code != 0 {
		t.Fatal(code)
	}

	if !strings.Contains(output.String(), "net-connector development revision unknown") {
		t.Fatalf("missing release identity: %q", output.String())
	}
}

func TestVersionBooleanFormsStayOffline(t *testing.T) {
	for _, flag := range []string{"--version=true", "-v=true"} {
		t.Run(flag, func(t *testing.T) {
			r, out, errout := fixtureRuntime(t)
			r.Args = []string{flag, "--config", "/does/not/exist"}
			if code := r.Run(t.Context()); code != 0 || !strings.Contains(out.String(), "net-connector") {
				t.Fatalf("code=%d out=%s err=%s", code, out.String(), errout.String())
			}
		})
	}
}

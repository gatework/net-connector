package vendors

import (
	"context"
	"strings"

	expect "github.com/gatework/go-expect"

	"github.com/gatework/net-connector/connector"
)

func testResultOutput(r connector.Result) string {
	if v, ok := r.Config(); ok {
		return v
	}
	v, e := r.JoinedOutput()
	if e != nil {
		panic(e)
	}
	return v
}

type patternInput struct{ *strings.Reader }

func (p patternInput) Write(b []byte) (int, error) { return len(b), nil }
func (p patternInput) Close() error                { return nil }
func matchesPattern(p expect.Pattern, text string) bool {
	s, e := expect.NewSession(patternInput{strings.NewReader(text)})
	if e != nil {
		panic(e)
	}
	defer s.Close()
	_, e = s.Expect(context.Background(), []expect.Case{{Pattern: p}})
	return e == nil
}

package connector

import (
	"context"
	"errors"
	"testing"
	"time"
)

func TestCallScopePreservesParentDeadline(t *testing.T) {
	t.Parallel()
	// Scope cancellation and direct parent propagation race at the same
	// deadline. Neither propagation order may turn a deadline into cancellation.
	for range 200 {
		parent, cancel := context.WithTimeout(t.Context(), time.Millisecond)
		scope := newCallScope(parent)
		ctx, leave, err := scope.enter(parent)
		if err != nil {
			cancel()
			t.Fatal(err)
		}
		<-ctx.Done()
		got := ctx.Err()
		leave()
		scope.end()
		cancel()
		if !errors.Is(got, context.DeadlineExceeded) {
			t.Fatalf("parent deadline became %v", got)
		}
	}
}

package connector

import (
	"context"
	"sync"
)

// callScope expires admission before cancelling and joining borrowed work.
// Callbacks and sinks remain cooperative; their owners never abandon them.
type callScope struct {
	mu           sync.Mutex
	active, busy bool
	ctx          context.Context //nolint:containedctx // a call scope is a lifecycle object; Close cancels it
	cancel       context.CancelFunc
	calls        sync.WaitGroup
}

func newCallScope(parent context.Context) *callScope {
	ctx, cancel := context.WithCancel(parent)
	return &callScope{active: true, ctx: ctx, cancel: cancel}
}
func (s *callScope) enter(parent context.Context) (context.Context, func(), error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.active {
		return nil, nil, ErrScope
	}
	if s.busy {
		return nil, nil, ErrBusy
	}
	s.busy = true
	s.calls.Add(1)
	ctx, cancel := context.WithCancel(parent)
	// If the caller is already done, its own propagation owns the error kind.
	// A competing scope callback must not replace DeadlineExceeded with Canceled.
	cancelScope := func() {
		if parent.Err() == nil {
			cancel()
		}
	}
	stop := context.AfterFunc(s.ctx, cancelScope)
	if s.ctx.Err() != nil {
		cancelScope()
	}
	return ctx, func() {
		stop()
		cancel()
		s.mu.Lock()
		s.busy = false
		s.mu.Unlock()
		s.calls.Done()
	}, nil
}
func (s *callScope) end() bool {
	s.mu.Lock()
	s.active = false
	pending := s.busy
	s.mu.Unlock()
	s.cancel()
	s.calls.Wait()
	return pending
}

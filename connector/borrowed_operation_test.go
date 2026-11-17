package connector

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type borrowedExchange struct {
	command, response string
	eof               bool
}

type borrowedWire struct {
	opens, closes atomic.Int32
	mu            sync.Mutex
	commands      []string
}

func (w *borrowedWire) transcript() []string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return slices.Clone(w.commands)
}

type borrowedConn struct {
	net.Conn
	wire       *borrowedWire
	failCloses int32
	closeErr   error
}

func (c *borrowedConn) Close() error {
	count := c.wire.closes.Add(1)
	err := c.Conn.Close()
	if count <= c.failCloses {
		return errors.Join(err, c.closeErr)
	}
	return err
}

func borrowedFixture(t *testing.T, p StaticDriver, cfg ConnectionConfig, exchanges []borrowedExchange, failCloses int32, closeErr error) (*Device, *borrowedWire) {
	t.Helper()
	wire := new(borrowedWire)
	var peers sync.WaitGroup
	cfg.Host, cfg.LoginTimeout, cfg.CommandTimeout = "fixture", time.Second, time.Second
	d, err := New(p, cfg, WithTransportFactory(func(context.Context, ConnectionConfig) (io.ReadWriteCloser, error) {
		wire.opens.Add(1)
		client, peer := net.Pipe()
		peers.Go(func() {
			defer peer.Close()
			if _, err := io.WriteString(peer, "sw#"); err != nil {
				return
			}
			scanner := bufio.NewScanner(peer)
			for _, exchange := range exchanges {
				if !scanner.Scan() {
					return
				}
				command := scanner.Text()
				wire.mu.Lock()
				wire.commands = append(wire.commands, command)
				wire.mu.Unlock()
				if command != exchange.command {
					t.Errorf("command = %q, want %q", command, exchange.command)
				}
				if _, err := io.WriteString(peer, exchange.response); err != nil || exchange.eof {
					return
				}
			}
			_, _ = io.Copy(io.Discard, peer)
		})
		return &borrowedConn{Conn: client, wire: wire, failCloses: failCloses, closeErr: closeErr}, nil
	}))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = d.Close()
		done := make(chan struct{})
		go func() { peers.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Error("borrowed session peer did not exit")
		}
	})
	return d, wire
}

func connectBorrowed(t *testing.T, d *Device) {
	t.Helper()
	if err := d.Connect(t.Context()); err != nil {
		t.Fatal(err)
	}
}

func TestBorrowedOperationRequiresConnectedLease(t *testing.T) {
	d, wire := borrowedFixture(t, fixtureDriver(), ConnectionConfig{}, nil, 0, nil)
	called := false
	run := func(context.Context, *Operation) error { called = true; return nil }
	operationErr, cleanupErr := d.WithBorrowedOperation(t.Context(), run)
	if !errors.Is(operationErr, ErrNotConnected) || cleanupErr != nil || called || wire.opens.Load() != 0 {
		t.Fatalf("operation=%v cleanup=%v called=%t opens=%d", operationErr, cleanupErr, called, wire.opens.Load())
	}
	connectBorrowed(t, d)
	operationErr, cleanupErr = d.WithBorrowedOperation(t.Context(), func(ctx context.Context, op *Operation) error {
		if !op.Connected() {
			t.Fatal("connected scope reports no session")
		}
		if err, _ := d.WithBorrowedOperation(ctx, run); !errors.Is(err, ErrBusy) {
			t.Fatalf("nested lease: %v", err)
		}
		if err := d.Connect(ctx); !errors.Is(err, ErrBusy) {
			t.Fatalf("Connect bypassed lease: %v", err)
		}
		return nil
	})
	if operationErr != nil || cleanupErr != nil || called || !d.Connected() || wire.opens.Load() != 1 {
		t.Fatalf("operation=%v cleanup=%v called=%t opens=%d", operationErr, cleanupErr, called, wire.opens.Load())
	}
}

func TestBorrowedRejectionPreservesOnlyVerifiedAttempt(t *testing.T) {
	d, wire := borrowedFixture(t, fixtureDriver(), ConnectionConfig{}, []borrowedExchange{
		{"query", "% Invalid input\nnext#", false},
		{"quit", "sw#", false},
	}, 0, nil)
	connectBorrowed(t, d)
	var saved *Operation
	operationErr, cleanupErr := d.WithBorrowedOperation(t.Context(), func(ctx context.Context, op *Operation) error {
		saved = op
		result, err := op.ExecuteCommand(ctx, Command{Text: "query", Prompt: testPattern(`(?m)(?:^|[\r\n])next#\s*$`)}, ExecuteOptions{
			PreserveSessionOnRejection: true,
			OnReceipt:                  func(context.Context, StepResult) error { t.Error("rejection became a receipt"); return nil },
			OnStep:                     func(context.Context, StepResult) error { t.Error("rejection became an accepted step"); return nil },
		})
		if !errors.Is(err, ErrDevice) || len(result.Steps()) != 0 || len(result.Attempts()) != 1 || !op.Connected() {
			t.Fatalf("result=%v err=%v connected=%t", result, err, op.Connected())
		}
		attempt := result.Attempts()[0]
		if !attempt.Complete() || attempt.Written() != len("query\n") || !errors.Is(attempt.Err(), ErrDevice) {
			t.Fatalf("attempt=%v", attempt)
		}
		if output, err := attempt.Response().Output(); err != nil || output != "% Invalid input\nnext#" {
			t.Fatalf("verified output=%q err=%v", output, err)
		}
		if prompt, err := op.Prompt(); err != nil || prompt != "next#" || op.RawPrompt() != "next#" {
			t.Fatalf("current prompt=%q err=%v", prompt, err)
		}
		_, err = op.ExecuteCommand(ctx, Command{Text: "quit"}, ExecuteOptions{})
		return err
	})
	if operationErr != nil || cleanupErr != nil || !d.Connected() || saved.Connected() || wire.opens.Load() != 1 {
		t.Fatalf("operation=%v cleanup=%v connected=%t", operationErr, cleanupErr, d.Connected())
	}
	if got := wire.transcript(); !slices.Equal(got, []string{"query", "quit"}) {
		t.Fatalf("wire=%q", got)
	}
	if _, err := saved.ExecuteCommand(t.Context(), Command{Text: "stale"}, ExecuteOptions{}); !errors.Is(err, ErrScope) {
		t.Fatalf("expired command: %v", err)
	}
}

func TestBorrowedPreservationValidationBeforeWrite(t *testing.T) {
	d, wire := borrowedFixture(t, fixtureDriver(), ConnectionConfig{}, nil, 0, nil)
	opts := ExecuteOptions{PreserveSessionOnRejection: true}
	if _, err := d.ExecuteCommand(t.Context(), Command{Text: "query"}, opts); !errors.Is(err, ErrInvalid) || wire.opens.Load() != 0 {
		t.Fatalf("ordinary command=%v opens=%d", err, wire.opens.Load())
	}
	if err := d.WithOperation(t.Context(), func(ctx context.Context, op *Operation) error {
		_, err := op.ExecuteCommand(ctx, Command{Text: "query"}, opts)
		if !errors.Is(err, ErrInvalid) {
			t.Fatalf("ordinary scope preservation: %v", err)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	connectBorrowed(t, d)
	operationErr, cleanupErr := d.WithBorrowedOperation(t.Context(), func(ctx context.Context, op *Operation) error {
		for _, commands := range [][]Command{nil, {{Text: "one"}, {Text: "two"}}} {
			if _, err := op.ExecuteScript(ctx, Script{Commands: commands}, opts); !errors.Is(err, ErrInvalid) {
				t.Fatalf("invalid script preservation: %v", err)
			}
		}
		if _, err := op.SaveConfig(ctx, opts); !errors.Is(err, ErrInvalid) {
			t.Fatalf("save preservation: %v", err)
		}
		return nil
	})
	if operationErr != nil || cleanupErr != nil || len(wire.transcript()) != 0 || !d.Connected() {
		t.Fatalf("operation=%v cleanup=%v commands=%q", operationErr, cleanupErr, wire.transcript())
	}
}

type borrowedEventSink struct {
	event string
	err   error
}

func (s borrowedEventSink) Write(p []byte) (int, error) {
	if strings.Contains(string(p), "event="+s.event) {
		return 0, s.err
	}
	return len(p), nil
}

func TestBorrowedRejectionRetiresOnIncompleteOrLateFailure(t *testing.T) {
	for _, kind := range []string{"default", "partial", "encoding", "script_limit", "output_limit", "command_observer", "operation_observer", "command_cancel", "operation_cancel", "command_log", "operation_log", "callback_error"} {
		t.Run(kind, func(t *testing.T) {
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			lateErr := errors.New("private observer or logger error")
			cfg := ConnectionConfig{}
			opts := ExecuteOptions{PreserveSessionOnRejection: kind != "default"}
			response, eof := "% Invalid input\nsw#", false
			switch kind {
			case "partial":
				response, eof = "% Invalid input", true
			case "encoding":
				response = "% Invalid input\xff\nsw#"
			case "script_limit":
				opts.MaxOutputBytes = 4
			case "output_limit":
				cfg.MaxOutputBytes = 8
			case "command_observer", "operation_observer", "command_cancel", "operation_cancel":
				name, _, _ := strings.Cut(kind, "_")
				cfg.OnSessionEvent = func(_ context.Context, event SessionEvent) error {
					if event.Name != name+"_complete" {
						return nil
					}
					if !strings.HasSuffix(kind, "_cancel") {
						return lateErr
					}
					cancel()
					return nil
				}
			case "command_log", "operation_log":
				name, _, _ := strings.Cut(kind, "_")
				cfg.Logger = borrowedEventSink{event: name + "_complete", err: lateErr}
				cfg.LogLevel = "info"
			case "callback_error":
				response = "accepted\nsw#"
				opts.OnReceipt = func(context.Context, StepResult) error { return lateErr }
			}
			d, wire := borrowedFixture(t, fixtureDriver(), cfg, []borrowedExchange{{"query", response, eof}}, 0, nil)
			connectBorrowed(t, d)
			operationErr, cleanupErr := d.WithBorrowedOperation(ctx, func(ctx context.Context, op *Operation) error {
				result, err := op.ExecuteCommand(ctx, Command{Text: "query"}, opts)
				if err == nil || op.Connected() || len(result.Attempts()) != 1 {
					t.Fatalf("operation=%v connected=%t attempts=%d", err, op.Connected(), len(result.Attempts()))
				}
				if kind != "callback_error" && len(result.Steps()) != 0 {
					t.Fatalf("failed attempt accepted: %v", result)
				}
				if strings.HasSuffix(kind, "_observer") || strings.HasSuffix(kind, "_log") || kind == "callback_error" {
					if !errors.Is(err, lateErr) {
						t.Fatalf("late failure lost: %v", err)
					}
				}
				//nolint:contextcheck // A fresh context must not revive a retired operation.
				if _, nextErr := op.ExecuteCommand(context.Background(), Command{Text: "never"}, ExecuteOptions{}); !errors.Is(nextErr, ErrScope) {
					t.Fatalf("retired scope reused: %v", nextErr)
				}
				return err
			})
			if operationErr == nil || d.Connected() || wire.opens.Load() != 1 || len(wire.transcript()) != 1 {
				t.Fatalf("operation=%v cleanup=%v opens=%d commands=%q", operationErr, cleanupErr, wire.opens.Load(), wire.transcript())
			}
		})
	}
}

func TestBorrowedRetireGuardsAndCleanupOwnership(t *testing.T) {
	for _, kind := range []string{"ignored_cleanup", "canceled", "callback_error"} {
		t.Run(kind, func(t *testing.T) {
			closeErr := errors.New("private cleanup detail")
			d, wire := borrowedFixture(t, fixtureDriver(), ConnectionConfig{}, nil, 2, closeErr)
			connectBorrowed(t, d)
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			var saved *Operation
			operationErr, cleanupErr := d.WithBorrowedOperation(ctx, func(_ context.Context, op *Operation) error {
				saved = op
				if kind == "canceled" {
					cancel()
				}
				if err := op.Retire(); !errors.Is(err, closeErr) {
					t.Fatalf("canceled retirement lost cleanup: %v", err)
				}
				if err := op.Retire(); !errors.Is(err, ErrScope) {
					t.Fatalf("repeated retirement: %v", err)
				}
				if op.Connected() || d.Connected() {
					t.Fatal("retired session is still connected")
				}
				//nolint:contextcheck // A fresh context must not revive a retired operation.
				if _, err := op.RunningConfig(context.Background()); !errors.Is(err, ErrScope) {
					t.Fatalf("retired configuration reconnected: %v", err)
				}
				if kind == "callback_error" {
					return ErrDevice
				}
				return nil // Neither a swallowed cleanup error nor cancellation may lose it.
			})
			var wantErr error
			switch kind {
			case "canceled":
				wantErr = context.Canceled
			case "callback_error":
				wantErr = ErrDevice
			}
			if !errors.Is(operationErr, wantErr) || !errors.Is(cleanupErr, closeErr) || errors.Is(operationErr, closeErr) {
				t.Fatalf("operation=%v cleanup=%v", operationErr, cleanupErr)
			}
			if calls := wire.closes.Load(); calls != 2 {
				t.Fatalf("scope exit repeated retirement: close calls=%d", calls)
			}
			if strings.Contains(fmt.Sprintf("%v %+v %#v", cleanupErr, cleanupErr, cleanupErr), "private cleanup") {
				t.Fatal("cleanup error formatting leaked its cause")
			}
			if err := saved.Retire(); !errors.Is(err, ErrScope) {
				t.Fatalf("stale retirement: %v", err)
			}
			if err := d.Close(); err != nil || wire.closes.Load() != 3 {
				t.Fatalf("explicit Close did not retry cleanup: %v calls=%d", err, wire.closes.Load())
			}
			if err := d.Connect(t.Context()); !errors.Is(err, ErrClosed) || wire.opens.Load() != 1 {
				t.Fatalf("terminal Close reconnected: %v opens=%d", err, wire.opens.Load())
			}
		})
	}
}

func TestBorrowedFailureKeepsCleanupSeparateWhenCallbackIgnoresErrors(t *testing.T) {
	closeErr := errors.New("transport cleanup failed")
	d, wire := borrowedFixture(t, fixtureDriver(), ConnectionConfig{}, []borrowedExchange{{"query", "% Invalid input\nsw#", false}}, 2, closeErr)
	connectBorrowed(t, d)
	operationErr, cleanupErr := d.WithBorrowedOperation(t.Context(), func(ctx context.Context, op *Operation) error {
		_, err := op.ExecuteCommand(ctx, Command{Text: "query"}, ExecuteOptions{})
		if !errors.Is(err, ErrDevice) || errors.Is(err, closeErr) {
			t.Fatalf("command and cleanup were conflated: %v", err)
		}
		return nil
	})
	if operationErr != nil || !errors.Is(cleanupErr, closeErr) || wire.closes.Load() != 2 || d.Connected() {
		t.Fatalf("operation=%v cleanup=%v closes=%d", operationErr, cleanupErr, wire.closes.Load())
	}
}

func TestBorrowedRetireRejectsReentryAndCloseCancelsCallback(t *testing.T) {
	d, wire := borrowedFixture(t, fixtureDriver(), ConnectionConfig{}, []borrowedExchange{{"query", "accepted\nsw#", false}}, 0, nil)
	connectBorrowed(t, d)
	operationErr, cleanupErr := d.WithBorrowedOperation(t.Context(), func(ctx context.Context, op *Operation) error {
		result, err := op.ExecuteCommand(ctx, Command{Text: "query"}, ExecuteOptions{OnReceipt: func(ctx context.Context, _ StepResult) error {
			if err := op.Retire(); !errors.Is(err, ErrBusy) {
				t.Fatalf("observer retirement: %v", err)
			}
			closed := make(chan error, 1)
			go func() { closed <- d.Close() }()
			select {
			case err := <-closed:
				if err != nil {
					t.Errorf("Close: %v", err)
				}
			case <-time.After(time.Second):
				t.Fatal("Close waited for callback")
			}
			if !errors.Is(ctx.Err(), context.Canceled) {
				t.Error("Close did not cancel callback context")
			}
			return nil
		}})
		if len(result.Steps()) != 1 {
			t.Fatal("Close discarded completed step")
		}
		return err
	})
	if !errors.Is(operationErr, context.Canceled) || cleanupErr != nil || wire.closes.Load() != 1 {
		t.Fatalf("operation=%v cleanup=%v closes=%d", operationErr, cleanupErr, wire.closes.Load())
	}
}

//nolint:contextcheck // An independent call context proves that scope expiry cancels and joins admitted work.
func TestBorrowedScopeJoinsCallAndRetainsCleanup(t *testing.T) {
	closeErr := errors.New("transport cleanup failed")
	d, wire := borrowedFixture(t, fixtureDriver(), ConnectionConfig{}, []borrowedExchange{{"query", "accepted\nsw#", false}}, 2, closeErr)
	connectBorrowed(t, d)
	entered := make(chan struct{})
	callDone := make(chan error, 1)
	operationErr, cleanupErr := d.WithBorrowedOperation(t.Context(), func(_ context.Context, op *Operation) error {
		go func() {
			_, err := op.ExecuteCommand(context.Background(), Command{Text: "query"}, ExecuteOptions{OnReceipt: func(ctx context.Context, _ StepResult) error {
				close(entered)
				<-ctx.Done()
				return ctx.Err()
			}})
			callDone <- err
		}()
		<-entered
		return nil
	})
	if !errors.Is(operationErr, context.Canceled) || !errors.Is(cleanupErr, closeErr) || wire.closes.Load() != 2 {
		t.Fatalf("operation=%v cleanup=%v closes=%d", operationErr, cleanupErr, wire.closes.Load())
	}
	if err := <-callDone; !errors.Is(err, context.Canceled) || errors.Is(err, closeErr) {
		t.Fatalf("call error=%v", err)
	}
}

func TestFinalObserverCancellationRetiresAcceptedResponse(t *testing.T) {
	for _, scope := range []string{"direct", "operation", "borrowed"} {
		t.Run(scope, func(t *testing.T) {
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			d, wire := borrowedFixture(t, fixtureDriver(), ConnectionConfig{OnSessionEvent: func(_ context.Context, event SessionEvent) error {
				if event.Name == "operation_complete" {
					cancel()
				}
				return nil
			}}, []borrowedExchange{{"query", "accepted\nsw#", false}}, 0, nil)
			connectBorrowed(t, d)
			check := func(result Result, err error) error {
				if !errors.Is(err, context.Canceled) || d.Connected() || len(result.Steps()) != 1 {
					t.Fatalf("late cancellation: err=%v connected=%t steps=%d", err, d.Connected(), len(result.Steps()))
				}
				step, receiptErr := result.SingleAccepted("query")
				if receiptErr != nil || step.Response().Raw() != "accepted\nsw#" {
					t.Fatalf("accepted response lost: receipt=%v raw=%q", receiptErr, step.Response().Raw())
				}
				return err
			}
			var operationErr, cleanupErr error
			switch scope {
			case "direct":
				operationErr = check(d.ExecuteCommand(ctx, Command{Text: "query"}, ExecuteOptions{}))
			case "operation":
				operationErr = d.WithOperation(ctx, func(ctx context.Context, op *Operation) error {
					return check(op.ExecuteCommand(ctx, Command{Text: "query"}, ExecuteOptions{}))
				})
			case "borrowed":
				operationErr, cleanupErr = d.WithBorrowedOperation(ctx, func(ctx context.Context, op *Operation) error {
					return check(op.ExecuteCommand(ctx, Command{Text: "query"}, ExecuteOptions{}))
				})
			}
			if !errors.Is(operationErr, context.Canceled) || cleanupErr != nil || wire.opens.Load() != 1 || wire.closes.Load() != 1 {
				t.Fatalf("operation=%v cleanup=%v opens=%d closes=%d", operationErr, cleanupErr, wire.opens.Load(), wire.closes.Load())
			}
		})
	}
}

func TestBorrowedRecoveredFinalObserverPanicStillRetires(t *testing.T) {
	closeErr := errors.New("transport cleanup failed")
	observerErr := errors.New("observer panic")
	d, wire := borrowedFixture(t, fixtureDriver(), ConnectionConfig{OnSessionEvent: func(_ context.Context, event SessionEvent) error {
		if event.Name == "operation_complete" {
			panic(observerErr)
		}
		return nil
	}}, []borrowedExchange{{"query", "% Invalid input\nsw#", false}}, 2, closeErr)
	connectBorrowed(t, d)
	operationErr, cleanupErr := d.WithBorrowedOperation(t.Context(), func(ctx context.Context, op *Operation) error {
		func() {
			defer func() {
				if recovered := recover(); recovered != observerErr { //nolint:errorlint // the panic value itself must be the observer error
					t.Errorf("panic=%v", recovered)
				}
			}()
			_, _ = op.ExecuteCommand(ctx, Command{Text: "query"}, ExecuteOptions{PreserveSessionOnRejection: true})
		}()
		if op.Connected() {
			t.Error("recovered final observer panic kept session alive")
		}
		return nil
	})
	if operationErr != nil || !errors.Is(cleanupErr, closeErr) || wire.closes.Load() != 2 {
		t.Fatalf("operation=%v cleanup=%v closes=%d", operationErr, cleanupErr, wire.closes.Load())
	}
}

func TestBorrowedConfigurationFailureRetiresOnlyOnce(t *testing.T) {
	for _, save := range []bool{false, true} {
		t.Run(fmt.Sprint(save), func(t *testing.T) {
			closeErr := errors.New("transport cleanup failed")
			profile := fixtureDriver()
			command, response, wantErr := "show config", "% Invalid input\nsw#", ErrDevice
			if save {
				profile.Grammar.SaveCommands = []string{"save"}
				command, response, wantErr = "save", "done\nsw#", ErrUnconfirmed
			}
			d, wire := borrowedFixture(t, profile, ConnectionConfig{}, []borrowedExchange{{command, response, false}}, 2, closeErr)
			connectBorrowed(t, d)
			operationErr, cleanupErr := d.WithBorrowedOperation(t.Context(), func(ctx context.Context, op *Operation) error {
				var err error
				if save {
					_, err = op.SaveConfig(ctx, ExecuteOptions{})
				} else {
					_, err = op.RunningConfig(ctx)
				}
				if !errors.Is(err, wantErr) || errors.Is(err, closeErr) || op.Connected() {
					t.Fatalf("configuration err=%v connected=%t", err, op.Connected())
				}
				return err
			})
			if !errors.Is(operationErr, wantErr) || !errors.Is(cleanupErr, closeErr) || wire.closes.Load() != 2 || wire.opens.Load() != 1 {
				t.Fatalf("operation=%v cleanup=%v closes=%d opens=%d", operationErr, cleanupErr, wire.closes.Load(), wire.opens.Load())
			}
		})
	}
}

func TestBorrowedRetirementNeedsExplicitReconnect(t *testing.T) {
	d, wire := borrowedFixture(t, fixtureDriver(), ConnectionConfig{}, nil, 0, nil)
	connectBorrowed(t, d)
	operationErr, cleanupErr := d.WithBorrowedOperation(t.Context(), func(_ context.Context, op *Operation) error { return op.Retire() })
	if operationErr != nil || cleanupErr != nil {
		t.Fatalf("operation=%v cleanup=%v", operationErr, cleanupErr)
	}
	if _, err := d.ExecuteCommand(t.Context(), Command{Text: "never"}, ExecuteOptions{}); !errors.Is(err, ErrNotConnected) {
		t.Fatalf("retired Device reconnected implicitly: %v", err)
	}
	if err, _ := d.WithBorrowedOperation(t.Context(), func(context.Context, *Operation) error {
		t.Error("borrowed retired session")
		return nil
	}); !errors.Is(err, ErrNotConnected) || wire.opens.Load() != 1 {
		t.Fatalf("borrowed scope reconnected implicitly: %v opens=%d", err, wire.opens.Load())
	}
	connectBorrowed(t, d)
	if !d.Connected() || wire.opens.Load() != 2 {
		t.Fatalf("explicit Connect failed: connected=%t opens=%d", d.Connected(), wire.opens.Load())
	}
}

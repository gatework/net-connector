package connector

import (
	"context"
	"errors"
	"testing"
)

func TestOperationHoldsLeaseAndExpires(t *testing.T) {
	d, _ := fixtureDevice(t, fixtureDriver(), []string{"one\nsw#", "two\nsw#"})
	var saved *Operation
	e := d.WithOperation(t.Context(), func(ctx context.Context, o *Operation) error {
		saved = o
		for range 2 {
			_, e := o.ExecuteCommand(ctx, Command{Text: "show"}, ExecuteOptions{OnReceipt: func(ctx context.Context, _ StepResult) error {
				_, e := o.ExecuteCommand(ctx, Command{Text: "nested"}, ExecuteOptions{})
				if !errors.Is(e, ErrBusy) {
					t.Errorf("nested: %v", e)
				}
				return nil
			}})
			if e != nil {
				return e
			}
		}
		return nil
	})
	if e != nil {
		t.Fatal(e)
	}
	if _, e = saved.ExecuteCommand(t.Context(), Command{Text: "expired"}, ExecuteOptions{}); !errors.Is(e, ErrScope) {
		t.Fatal(e)
	}
}

package workflow

import (
	"context"
	"errors"

	"github.com/gatework/net-connector/archive"
	"github.com/gatework/net-connector/connector"
	"github.com/gatework/net-connector/fleet"
	"github.com/gatework/net-connector/internal/batchreport"
	"github.com/gatework/net-connector/platform"
	"github.com/gatework/net-connector/storage"
	"github.com/gatework/net-connector/topology"
	"github.com/gatework/net-connector/transfer"
)

// classify returns a safe code and phase for err: only classified metadata,
// never error text that could contain device output or secrets. stage is the
// fallback phase. A later cleanup error never relabels the primary failure,
// so only the primary branch of a joined error is inspected.
func classify(err error, stage string) batchreport.Diagnostic {
	switch {
	case errors.Is(err, fleet.ErrMissingCredentials):
		return batchreport.Diagnostic{Code: "missing_credentials", Phase: "authenticate"}
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return batchreport.Diagnostic{Code: "interrupted", Phase: stage}
	}
	for current := err; current != nil; current = primaryCause(current) {
		switch e := current.(type) { //nolint:errorlint // walks the primary branch one level at a time.
		case *connector.Error:
			return batchreport.Diagnostic{Code: e.Code, Phase: e.Phase}
		case *topology.Error:
			return batchreport.Diagnostic{Code: e.Code, Phase: e.Phase}
		case *transfer.Error:
			return batchreport.Diagnostic{Code: e.Code, Phase: e.Phase}
		case *archive.Error:
			return batchreport.Diagnostic{Code: "archive_failed", Phase: e.Phase}
		case *storage.WriteError:
			code := "file_write_failed"
			if e.Receipt.Committed() {
				code = "file_persistence_unconfirmed"
			}
			return batchreport.Diagnostic{Code: code, Phase: stage}
		case platform.DiagnosticMetadata:
			if e.DiagnosticCode() != "" && e.DiagnosticPhase() != "" {
				return batchreport.Diagnostic{Code: e.DiagnosticCode(), Phase: e.DiagnosticPhase()}
			}
		}
	}
	switch {
	case errors.Is(err, connector.ErrUnconfirmed):
		return batchreport.Diagnostic{Code: "persistence_unconfirmed", Phase: stage}
	case errors.Is(err, connector.ErrUnsupported), errors.Is(err, platform.ErrUnsupported):
		return batchreport.Diagnostic{Code: "unsupported_operation", Phase: stage}
	case errors.Is(err, connector.ErrIncomplete):
		return batchreport.Diagnostic{Code: "incomplete", Phase: stage}
	}
	return batchreport.Diagnostic{Code: "internal_error", Phase: stage}
}

// primaryCause unwraps one level, following only the first branch of a join.
func primaryCause(err error) error {
	switch wrapped := err.(type) { //nolint:errorlint // inspects this level's unwrap shape.
	case interface{ Unwrap() []error }:
		if causes := wrapped.Unwrap(); len(causes) > 0 {
			return causes[0]
		}
		return nil
	case interface{ Unwrap() error }:
		return wrapped.Unwrap()
	}
	return nil
}

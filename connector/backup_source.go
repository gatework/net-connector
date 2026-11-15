package connector

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"os"
	"slices"
	"strings"
	"syscall"

	"github.com/gatework/net-connector/storage"
)

// BackupSource identifies unmodified command responses; it excludes login data.
type BackupSource struct {
	Path            string          `json:"path"`
	Bytes           int             `json:"bytes"`
	SHA256          string          `json:"sha256"`
	File            storage.Receipt `json:"file"`
	NoWriteVerified bool            `json:"no_write_verified"`
	Segments        []SourceSegment `json:"segments"`
}

// SourceSegment maps one accepted command response to its raw backup offset.
type SourceSegment struct {
	Step   int `json:"step"`
	Offset int `json:"offset"`
	Bytes  int `json:"bytes"`
}

// TextPosition uses zero-based raw file offsets, one-based lines/byte columns.
type TextPosition struct {
	Offset int `json:"offset"`
	Line   int `json:"line"`
	Column int `json:"column"`
}

// TextWarning records invalid-encoding counts and bounded source positions.
type TextWarning struct {
	Count     int            `json:"count"`
	Positions []TextPosition `json:"positions"`
}

// Clone owns mutable metadata while sharing immutable strings.
func (r BackupReceipt) Clone() BackupReceipt {
	if r.Source != nil {
		v := *r.Source
		v.Segments = slices.Clone(v.Segments)
		r.Source = &v
	}
	if r.TextWarning != nil {
		v := *r.TextWarning
		v.Positions = slices.Clone(v.Positions)
		r.TextWarning = &v
	}
	return r
}

func backupSource(result Result) ([]string, *BackupSource, string, *TextWarning) {
	var parts []string
	size := 0
	source := &BackupSource{}
	encoding := "utf-8"
	for i, step := range result.steps {
		source.Segments = append(source.Segments, SourceSegment{Step: i + 1, Offset: size, Bytes: len(step.Response().Raw())})
		part := step.Response().Raw()
		parts = append(parts, part)
		size += len(part)
		e := step.Response().Encoding()
		if e == "escaped" {
			encoding = e
		} else if encoding != "escaped" && e != "utf-8" && e != "" {
			if encoding != "utf-8" && encoding != e {
				encoding = "mixed"
			} else {
				encoding = e
			}
		}
	}
	source.Bytes = size
	source.SHA256 = hashParts(parts)
	warning := &TextWarning{}
	offset, line, column := 0, 1, 1
	for _, step := range result.steps {
		response := step.Response()
		if data := response.data; data != nil && data.rawWarning != nil {
			warning.Count += data.rawWarning.Count
			for _, p := range data.rawWarning.Positions {
				if len(warning.Positions) >= 64 {
					break
				}
				p.Offset += offset
				if p.Line == 1 {
					p.Column += column - 1
				}
				p.Line += line - 1
				warning.Positions = append(warning.Positions, p)
			}
		}
		raw := response.Raw()
		advanceTextPosition(raw, &line, &column)
		offset += len(raw)
	}
	if warning.Count == 0 {
		warning = nil
	}
	return parts, source, encoding, warning
}

func persistBackupSource(ctx context.Context, source *BackupSource, parts []string, path string) error {
	source.Path = path + "." + source.SHA256 + ".raw"
	source.File = storage.Receipt{Path: source.Path, State: storage.StateNotCommitted, Phase: "compare"}
	previous, e := storage.Inspect(ctx, source.Path, int64(source.Bytes))
	if e != nil && !os.IsNotExist(e) {
		return e
	}
	if previous.SHA256 != "" && previous.SHA256 != source.SHA256 {
		return storage.ErrUnsafe
	}
	if previous.SHA256 == source.SHA256 && previous.Mode.Perm() == 0600 && storage.SameEntry(source.Path, previous) {
		source.NoWriteVerified = true
		source.File = storage.Receipt{Path: source.Path, State: storage.StateNotCommitted, Phase: "compare"}
		return nil
	}
	source.File, e = storage.WriteStream(ctx, source.Path, func(w io.Writer) error {
		for _, part := range parts {
			if _, err := io.WriteString(w, part); err != nil {
				return err
			}
		}
		return nil
	})
	return backupPersistenceFailure(source.File, e)
}

// hashParts fingerprints immutable response segments without a body-sized copy.
func hashParts(parts []string) string {
	h := sha256.New()
	scratch := make([]byte, 32<<10)
	for _, part := range parts {
		for len(part) > 0 {
			n := copy(scratch, part)
			_, _ = h.Write(scratch[:n])
			part = part[n:]
		}
	}
	return fmt.Sprintf("%x", h.Sum(nil))
}

func backupPersistenceFailure(receipt storage.Receipt, err error) error {
	if err == nil || !receipt.Committed() {
		return err
	}
	code := "backup_persistence_unconfirmed"
	if receipt.Durable() {
		code = "backup_finalize_failed"
	}
	if receipt.Phase == "directory_sync" && (errors.Is(err, syscall.EINVAL) || errors.Is(err, syscall.ENOSYS) || errors.Is(err, syscall.ENOTSUP) || errors.Is(err, syscall.EOPNOTSUPP)) {
		code = "backup_durability_unsupported"
	}
	return &BackupPersistenceError{failure: &Error{Code: code, Phase: "backup", cause: err}}
}

// Verified reports durable storage or verification of unchanged source bytes.
func (s BackupSource) Verified() bool { return s.File.Durable() || s.NoWriteVerified }

// HasSavedEvidence reports whether any backup evidence was committed or verified unchanged.
func (r BackupReceipt) HasSavedEvidence() bool {
	return r.File.Committed() || (r.DeviceCompleted && r.Change == "unchanged" && r.NoWriteVerified) || (r.Source != nil && r.Source.File.Committed())
}

// Complete requires device completion and verified text and source persistence.
func (r BackupReceipt) Complete() bool {
	return r.DeviceCompleted && (r.File.Durable() || (r.Change == "unchanged" && r.NoWriteVerified)) && (r.TextOnly || r.Source != nil && r.Source.Verified())
}

// HasUnverifiedPair reports incomplete raw/text file durability without treating
// a committed file as a complete backup. Source-less legacy receipts have no
// pair; Complete is the stricter contract for newly produced receipts.
func (r BackupReceipt) HasUnverifiedPair() bool {
	return r.Source != nil && (!(r.File.Durable() || r.NoWriteVerified) || !r.Source.Verified())
}

// SourceEvidence supplies the same persistence facts to progress and reports.
// In text-only mode the text file is the retained source; otherwise its raw
// sidecar supplies the evidence, including verified unchanged files.
func (r BackupReceipt) SourceEvidence() (committed, verified bool) {
	if r.TextOnly {
		return r.HasSavedEvidence(), r.Complete()
	}
	if r.Source != nil {
		return r.Source.File.Committed(), r.Source.Verified()
	}
	return false, false
}

// sourceWarning records positions from the same pass that produced diagnostic
// text. Persistence consumes this immutable metadata without decoding again.
func sourceWarning(raw string, count int, offsets []int) *TextWarning {
	if count == 0 {
		return nil
	}
	warning := &TextWarning{Count: count}
	previous, line, column := 0, 1, 1
	for _, offset := range offsets {
		advanceTextPosition(raw[previous:offset], &line, &column)
		warning.Positions = append(warning.Positions, TextPosition{Offset: offset, Line: line, Column: column})
		previous = offset
	}
	return warning
}
func advanceTextPosition(text string, line, column *int) {
	if last := strings.LastIndexByte(text, '\n'); last >= 0 {
		*line += strings.Count(text, "\n")
		*column = len(text) - last
	} else {
		*column += len(text)
	}
}

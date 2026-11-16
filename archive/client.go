package archive

import (
	"context"
	"errors"
	"io"
	"path/filepath"
	"sync"
	"time"

	"github.com/gatework/net-connector/storage"
	"github.com/gatework/net-connector/transfer"
)

// ClientOptions selects archive storage, a worker launcher and phase timeouts.
type ClientOptions struct {
	Root, Directory string
	Launcher        Launcher
	Timeouts        Timeouts
}

// Client coordinates bounded archive transactions and owns worker cleanup.
type Client struct {
	cleanupMu              sync.Mutex
	pending                []func() error
	active                 int
	closed                 bool
	root, directory, batch string
	launch                 Launcher
	timeouts               Timeouts
	persist                func(context.Context, string, func(io.Writer) error) (storage.Receipt, error)
	slots                  chan struct{}
	prepareGate            chan struct{}
	mu                     sync.Mutex
	prepared               bool
}

// NewClient validates options without starting a worker or accessing storage.
func NewClient(o ClientOptions) (*Client, error) {
	if !filepath.IsAbs(o.Root) || filepath.Clean(o.Root) != o.Root || o.Directory == "" || o.Launcher == nil {
		return nil, ErrArchive
	}
	timeouts, e := o.Timeouts.normalize()
	if e != nil {
		return nil, e
	}
	directory, e := filepath.Abs(o.Directory)
	if e != nil {
		return nil, e
	}
	batch := time.Now().In(time.FixedZone("UTC+8", 8*3600)).Format("2006-01-02")
	return &Client{root: o.Root, directory: directory, batch: batch, launch: o.Launcher, timeouts: timeouts, persist: storage.WriteStream, slots: make(chan struct{}, 4), prepareGate: make(chan struct{}, 1)}, nil
}

// Prepare initializes local storage and verifies the worker protocol capabilities.
func (c *Client) Prepare(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, c.timeouts.Prepare)
	defer cancel()
	if err := ctx.Err(); err != nil {
		return err
	}
	select {
	case c.prepareGate <- struct{}{}:
	case <-ctx.Done():
		return ctx.Err()
	}
	defer func() { <-c.prepareGate }()
	if err := ctx.Err(); err != nil {
		return err
	}
	c.cleanupMu.Lock()
	if c.closed {
		c.cleanupMu.Unlock()
		return ErrArchive
	}
	// Own the whole initialization, including local directory preparation.
	c.active++
	c.cleanupMu.Unlock()
	defer func() { c.cleanupMu.Lock(); c.active--; c.cleanupMu.Unlock() }()
	c.mu.Lock()
	prepared := c.prepared
	c.mu.Unlock()
	if prepared {
		return nil
	}
	if e := storage.PrepareDirectory(filepath.Join(c.directory, "tftp")); e != nil {
		return e
	}
	probeCtx, cancelProbe := context.WithTimeout(ctx, controlTimeout)
	defer cancelProbe()
	e := c.channel(probeCtx, func(p *Protocol) error {
		ctx := probeCtx
		if e := p.Send(ctx, Request{Action: "probe"}); e != nil {
			return e
		}
		if _, e := p.Expect(ctx, "ready"); e != nil {
			return e
		}
		if p.last.Version != Version {
			return ErrArchive
		}
		found := map[string]bool{}
		for _, v := range p.last.Capabilities {
			found[v] = true
		}
		for _, v := range capabilities {
			if !found[v] {
				return ErrArchive
			}
		}
		return nil
	})
	if e != nil {
		return e
	}
	preflightCtx, cancelPreflight := context.WithTimeout(ctx, controlTimeout)
	defer cancelPreflight()
	e = c.channel(preflightCtx, func(p *Protocol) error {
		ctx := preflightCtx
		if e := p.Send(ctx, Request{Action: "preflight", Root: c.root, Filename: "preflight.cfg", ArchiveName: "preflight.cfg", Batch: c.batch}); e != nil {
			return e
		}
		_, e := p.Expect(ctx, "ready")
		return e
	})
	if e == nil {
		e = ctx.Err()
	}
	if e == nil {
		c.mu.Lock()
		c.prepared = true
		c.mu.Unlock()
	}
	return e
}

// Upload owns one target transaction. Independent child contexts prevent queue
// time from consuming the upload window, without detaching from caller cancel.
func (c *Client) Upload(ctx context.Context, filename, archiveName string, upload func(context.Context, string) (transfer.Receipt, error)) (Result, error) {
	prepare, cancel := context.WithTimeout(ctx, c.timeouts.Prepare)
	defer cancel()
	return c.upload(ctx, prepare, filename, archiveName, upload)
}

// Close rejects new transactions and retries pending channel cleanup. Call after
// transactions return; active work belongs to its context and returns ErrArchive.
// Pool cancels and joins admitted work before calling this method.
func (c *Client) Close() error {
	c.cleanupMu.Lock()
	defer c.cleanupMu.Unlock()
	if c.active != 0 {
		return ErrArchive
	}
	c.closed = true
	var failed []func() error
	var err error
	for _, closeFn := range c.pending {
		if e := closeFn(); e != nil {
			err = errors.Join(err, e)
			failed = append(failed, closeFn)
		}
	}
	c.pending = failed
	if err != nil {
		return &Error{cause: err}
	}
	return nil
}

func (c *Client) channel(ctx context.Context, run func(*Protocol) error) error {
	return c.channelWithin(ctx, ctx, run)
}

func (c *Client) channelWithin(ctx, admission context.Context, run func(*Protocol) error) (err error) {
	if err := ctx.Err(); err != nil {
		return err
	}
	c.cleanupMu.Lock()
	if c.closed {
		c.cleanupMu.Unlock()
		return ErrArchive
	}
	c.active++
	c.cleanupMu.Unlock()
	defer func() { c.cleanupMu.Lock(); c.active--; c.cleanupMu.Unlock() }()
	select {
	case c.slots <- struct{}{}:
	case <-admission.Done():
		return stageFailure("prepare", admission.Err())
	}
	defer func() { <-c.slots }()
	if err := admission.Err(); err != nil {
		return stageFailure("prepare", err)
	}
	// The launcher must honor admission cancellation, but the launched worker
	// belongs to the transaction, not to the expiring preparation context.
	channelCtx, cancelChannel := context.WithCancel(ctx)
	defer cancelChannel()
	launch := func(context.Context) (Channel, error) {
		stop := context.AfterFunc(admission, cancelChannel)
		if admission.Err() != nil {
			cancelChannel()
		}
		ch, err := c.launch(channelCtx)
		if !stop() {
			cancelChannel()
		}
		if admission.Err() != nil {
			// Cancellation is how the launcher is interrupted, not the cause of
			// the preparation failure. Put the stage deadline first while retaining
			// every launcher cause, including parallel I/O or cleanup failures.
			return ch, errors.Join(stageFailure("prepare", admission.Err()), err)
		}
		return ch, errors.Join(err, channelCtx.Err())
	}
	return runChannel(channelCtx, launch, run, func(closeFn func() error) {
		c.cleanupMu.Lock()
		c.pending = append(c.pending, closeFn)
		c.cleanupMu.Unlock()
	})
}

func (c *Client) upload(ctx, prepare context.Context, filename, archiveName string, upload func(context.Context, string) (transfer.Receipt, error)) (result Result, err error) {
	result.Receipt.Cleanup = CleanupNotRequested
	c.mu.Lock()
	prepared := c.prepared
	c.mu.Unlock()
	if !prepared || !isSafeName(filename) || !isSafeName(archiveName) || upload == nil {
		return result, stageFailure("prepare", ErrArchive)
	}
	err = c.channelWithin(ctx, prepare, func(p *Protocol) error {
		budgets, e := c.timeouts.wire(prepare)
		if e != nil {
			return e
		}
		request := Request{Root: c.root, Filename: filename, ArchiveName: archiveName, Batch: c.batch, Timeouts: &budgets}
		if e := p.Send(prepare, request); e != nil {
			return stageFailure("prepare", e)
		}
		if _, e := p.Expect(prepare, "ready"); e != nil {
			return stageFailure("prepare", e)
		}
		if e := prepare.Err(); e != nil {
			return stageFailure("prepare", e)
		}

		var primary error
		result.Transfer, primary = c.runUpload(ctx, filename, upload)
		if primary != nil {
			primary = stageFailure("upload", primary)
		}
		if !result.Transfer.Reported() || result.Transfer.Path != filename {
			c.abort(ctx, p)
			if primary != nil {
				return primary
			}
			return stageFailure("upload", ErrArchive)
		}

		return c.verifyUpload(ctx, p, archiveName, primary, &result)

	})
	return result, err
}

// runUpload owns the callback budget even when the callback panics or exits.
func (c *Client) runUpload(ctx context.Context, filename string, upload func(context.Context, string) (transfer.Receipt, error)) (transfer.Receipt, error) {
	uploadCtx, cancel := context.WithTimeout(ctx, c.timeouts.Upload)
	defer cancel()
	receipt, err := upload(uploadCtx, filename)
	return receipt, errors.Join(err, uploadCtx.Err())
}

func (c *Client) verifyUpload(ctx context.Context, p *Protocol, archiveName string, primary error, result *Result) error {
	verifyCtx, cancelVerify := context.WithTimeout(ctx, c.timeouts.Verify)
	defer cancelVerify()
	if e := p.Send(verifyCtx, Request{Action: "verify"}); e != nil {
		return errors.Join(primary, stageFailure("verify", e))
	}
	proof, e := p.Expect(verifyCtx, "archived")
	if e != nil {
		return errors.Join(primary, stageFailure("verify", e))
	}
	if proof.ArchivePath != filepath.Join(c.root, "archive", c.batch, archiveName) {
		return errors.Join(primary, stageFailure("verify", ErrArchive))
	}
	result.Receipt.Server = &proof
	destination := filepath.Join(c.directory, "tftp", archiveName)
	called := false
	received := proof
	fileReceipt, persistErr := c.persist(verifyCtx, destination, func(w io.Writer) error {
		called = true
		var e error
		received, e = p.Receive(verifyCtx, proof, w)
		return e
	})
	result.Receipt.Local = fileReceipt
	if !called {
		var receiveErr error
		received, receiveErr = p.Receive(verifyCtx, proof, io.Discard)
		persistErr = errors.Join(persistErr, receiveErr)
	}
	result.Receipt.Server = &received
	persistErr = errors.Join(persistErr, verifyCtx.Err())
	if primary != nil || persistErr != nil || !result.Receipt.Verified() || !fileReceipt.Durable() {
		c.abort(ctx, p)
		if persistErr != nil {
			return errors.Join(primary, stageFailure("verify", persistErr))
		}
		if primary != nil {
			return primary
		}
		return stageFailure("verify", ErrArchive)
	}
	cleanupCtx, cancelCleanup := context.WithTimeout(ctx, c.timeouts.Cleanup)
	defer cancelCleanup()
	result.Receipt.Cleanup = CleanupUnconfirmed
	if e = p.Send(cleanupCtx, Request{Action: "cleanup", SHA256: received.SHA256}); e != nil {
		return stageFailure("cleanup", e)
	}
	if _, e = p.Expect(cleanupCtx, "complete"); e != nil {
		return stageFailure("cleanup", e)
	}
	result.Receipt.Cleanup = CleanupComplete
	return nil
}

func (c *Client) abort(ctx context.Context, p *Protocol) {
	control, cancel := context.WithTimeout(ctx, controlTimeout)
	defer cancel()
	_ = p.Send(control, Request{Action: "abort"})
}

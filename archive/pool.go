package archive

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gatework/net-connector/transfer"
)

// PoolOptions describes local or SSH archive storage. NewPool does no I/O.
type PoolOptions struct {
	Root, Directory, WorkerPath, Password string
	Parallel                              int
	Timeouts                              Timeouts
}

// PrepareStage identifies the safe phase of archive service preparation.
type PrepareStage string

// Archive preparation stages.
const (
	PrepareStageSSH      PrepareStage = "ssh"
	PrepareStageProtocol PrepareStage = "protocol"
	PrepareStageReady    PrepareStage = "ready"
)

// PrepareProgress reports bounded archive preparation metadata.
type PrepareProgress struct {
	Completed, Total, Active int
	Workers                  int
	Stage                    PrepareStage
}

// Pool owns archive clients and their optional SSH masters.
type Pool struct {
	timeouts                             Timeouts
	clients                              []*Client
	masters                              []*sshMaster
	available                            chan *Client
	endpoint                             *url.URL
	mu                                   sync.Mutex
	prepared, closed, cleaned, preparing bool
	prepareDone                          chan struct{}
	prepareCancel                        context.CancelFunc
	closeDone                            chan struct{}
	closeErr                             error
	stop                                 chan struct{}
	active                               sync.WaitGroup
}

// NewPool validates and groups archive destinations without connecting.
func NewPool(o PoolOptions) (*Pool, error) {
	timeouts, err := o.Timeouts.normalize()
	if err != nil {
		return nil, err
	}
	if o.Parallel < 1 || o.Parallel > 500 || o.Directory == "" || strings.ContainsAny(o.Password, "\x00\r\n") {
		return nil, ErrArchive
	}
	root, err := transfer.VerificationRoot(o.Root)
	if err != nil {
		return nil, err
	}
	worker := o.WorkerPath
	if worker == "" {
		worker = DefaultWorkerPath
	}
	if !safeWorkerPath(worker) {
		return nil, ErrArchive
	}
	p := &Pool{timeouts: timeouts, available: make(chan *Client, o.Parallel), stop: make(chan struct{}), closeDone: make(chan struct{})}
	clientRoot := root
	if strings.HasPrefix(root, "ssh://") {
		p.endpoint, clientRoot, err = parseArchiveEndpoint(root)
		if err != nil {
			return nil, err
		}
	}
	for remaining := o.Parallel; remaining > 0; {
		count := min(remaining, 4)
		var launch Launcher
		if p.endpoint != nil {
			master := &sshMaster{endpoint: p.endpoint, worker: worker, password: o.Password}
			p.masters = append(p.masters, master)
			launch = master.launch
		} else {
			launch = LocalLauncher()
		}
		client, e := NewClient(ClientOptions{Root: clientRoot, Directory: o.Directory, Launcher: launch, Timeouts: timeouts})
		if e != nil {
			return nil, e
		}
		if len(p.clients) > 0 {
			client.batch = p.clients[0].batch
		}
		p.clients = append(p.clients, client)
		for range count {
			p.available <- client
		}
		remaining -= count
	}
	return p, nil
}

// Prepare preflights every master, protocol version and archive directory.
// A non-nil observe receives stage counts without credentials or protocol
// bodies on the calling goroutine. Close can cancel and join this work even
// without a caller deadline. During initial preparation, an observer panic or
// Goexit retires the pool.
func (p *Pool) Prepare(ctx context.Context, observe func(PrepareProgress)) error {
	return p.prepare(ctx, observe)
}

// Upload borrows one of at most Parallel slots and returns it after the transaction.
func (p *Pool) Upload(ctx context.Context, filename, archiveName string, upload func(context.Context, string) (transfer.Receipt, error)) (Result, error) {
	prepare, cancelPrepare := context.WithTimeout(ctx, p.timeouts.Prepare)
	defer cancelPrepare()
	p.mu.Lock()
	if !p.prepared || p.closed {
		p.mu.Unlock()
		return Result{}, ErrArchive
	}
	p.active.Add(1)
	p.mu.Unlock()
	defer p.active.Done()
	select {
	case <-prepare.Done():
		return Result{}, stageFailure("prepare", prepare.Err())
	case <-p.stop:
		return Result{}, ErrArchive
	case client := <-p.available:
		defer func() { p.available <- client }()
		select {
		case <-p.stop:
			return Result{}, ErrArchive
		default:
		}
		callCtx, cancel := context.WithCancel(ctx)
		stop := context.AfterFunc(&poolDoneContext{done: p.stop}, cancel) //nolint:contextcheck // Pool shutdown is an independent cancellation source combined with callCtx.
		defer func() { stop(); cancel() }()
		// Prepare admission must also observe Pool.Close, while keeping its
		// original deadline across the local queue and the server's target lock.
		admission, cancelAdmission := context.WithCancel(prepare)
		stopAdmission := context.AfterFunc(callCtx, cancelAdmission)
		defer func() { stopAdmission(); cancelAdmission() }()
		receipt, err := client.upload(callCtx, admission, filename, archiveName, upload)
		if p.endpoint != nil && receipt.Receipt.Server != nil && receipt.Receipt.Server.ArchivePath != "" {
			u := *p.endpoint
			u.Path, u.RawPath = receipt.Receipt.Server.ArchivePath, ""
			receipt.Receipt.Server.ArchivePath = u.String()
		}
		return receipt, err
	}
}

// Close cancels and joins admitted work before releasing clients and SSH masters.
func (p *Pool) Close() error {
	p.mu.Lock()
	if p.closed && p.cleaned && p.closeErr != nil {
		// A completed failed attempt retains owners; a later Close retries them.
		p.cleaned = false
		p.closeDone = make(chan struct{})
		defer p.mu.Unlock()
		return p.closeLocked()
	}
	if p.closed {
		done := p.closeDone
		p.mu.Unlock()
		<-done
		p.mu.Lock()
		defer p.mu.Unlock()
		return p.closeErr
	}
	p.closed = true
	close(p.stop)
	if p.prepareCancel != nil {
		p.prepareCancel()
	}
	prepDone := p.prepareDone
	p.mu.Unlock()
	if prepDone != nil {
		<-prepDone
	}
	p.active.Wait()
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.closeLocked()
}

// ArchiveDirectory returns the server directory after successful preparation.
func (p *Pool) ArchiveDirectory() string {
	return filepath.Join(p.clients[0].root, "archive", p.clients[0].batch)
}

func (p *Pool) prepare(ctx context.Context, observe func(PrepareProgress)) (err error) {
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		p.mu.Lock()
		if p.closed {
			p.mu.Unlock()
			return ErrArchive
		}
		if p.prepared {
			progress := PrepareProgress{Completed: len(p.clients), Total: len(p.clients), Workers: p.preparationWorkers(), Stage: PrepareStageReady}
			p.mu.Unlock()
			if observe != nil {
				observe(progress)
			}
			return ctx.Err()
		}
		if p.preparing {
			done := p.prepareDone
			p.mu.Unlock()
			select {
			case <-done:
				continue
			case <-ctx.Done():
				return ctx.Err()
			}
		}
		prepCtx, cancel := context.WithCancel(ctx)
		p.preparing = true
		p.prepareDone = make(chan struct{})
		p.prepareCancel = cancel
		p.mu.Unlock()

		returned := false
		defer func() {
			if returned && err == nil {
				err = prepCtx.Err()
			}
			cancel()
			p.mu.Lock()
			if p.closed && err == nil {
				err = context.Canceled
			}
			p.preparing = false
			p.prepareCancel = nil
			p.prepared = returned && err == nil
			close(p.prepareDone)
			p.mu.Unlock()
			if !returned {
				_ = p.Close()
			} else if err != nil {
				err = errors.Join(err, p.Close())
			}
		}()
		err = p.prepareAll(prepCtx, observe)
		returned = true
		return err
	}
}

func (p *Pool) prepareAll(ctx context.Context, observe func(PrepareProgress)) error {
	if p.endpoint == nil {
		batch, err := reserveLocalBatch(ctx, p.clients[0].root, p.clients[0].directory)
		if err != nil {
			return err
		}
		for _, client := range p.clients {
			client.batch = batch
		}
		if observe != nil {
			observe(PrepareProgress{Total: len(p.clients), Workers: 1, Stage: PrepareStageProtocol})
		}
		completed := 0
		for _, client := range p.clients {
			if err := ctx.Err(); err != nil {
				return err
			}
			if observe != nil {
				observe(PrepareProgress{Completed: completed, Total: len(p.clients), Active: 1, Workers: 1, Stage: PrepareStageProtocol})
			}
			err := client.Prepare(ctx)
			if err != nil {
				if observe != nil {
					observe(PrepareProgress{Completed: completed, Total: len(p.clients), Workers: 1, Stage: PrepareStageProtocol})
				}
				return err
			}
			completed++
			if observe != nil {
				observe(PrepareProgress{Completed: completed, Total: len(p.clients), Workers: 1, Stage: PrepareStageProtocol})
			}
		}
		if observe != nil {
			observe(PrepareProgress{Completed: completed, Total: len(p.clients), Workers: 1, Stage: PrepareStageReady})
		}
		return nil
	}

	return p.prepareRemote(ctx, observe)
}

type poolDoneContext struct{ done <-chan struct{} }

func (c *poolDoneContext) Deadline() (deadline time.Time, ok bool) { return }
func (c *poolDoneContext) Done() <-chan struct{}                   { return c.done }
func (c *poolDoneContext) Err() error {
	select {
	case <-c.done:
		return context.Canceled
	default:
		return nil
	}
}
func (c *poolDoneContext) Value(any) any { return nil }

func (p *Pool) prepareRemote(ctx context.Context, observe func(PrepareProgress)) error {
	workerCtx, cancel := context.WithCancel(ctx)
	var next atomic.Int64
	var completed, active int
	workers := p.preparationWorkers()
	var errorMu sync.Mutex
	var firstErr error
	recordError := func(err error) {
		if err == nil {
			return
		}
		errorMu.Lock()
		if firstErr == nil {
			firstErr = err
			cancel()
		}
		errorMu.Unlock()
	}
	updates := make(chan preparationUpdate)
	done := make(chan struct{})
	defer func() {
		cancel()
		<-done
	}()
	go func() {
		defer close(done)
		defer close(updates)
		report := func(stage PrepareStage, activeDelta, completedDelta int) {
			select {
			case updates <- preparationUpdate{stage, activeDelta, completedDelta}:
			case <-workerCtx.Done():
			}
		}
		p.runPreparationWorkers(workerCtx, workers, &next, report, recordError)
	}()
	for update := range updates {
		if workerCtx.Err() != nil {
			continue
		}
		active += update.activeDelta
		completed += update.completedDelta
		if observe != nil {
			observe(PrepareProgress{Completed: completed, Total: len(p.clients), Active: active, Workers: workers, Stage: update.stage})
		}
	}

	errorMu.Lock()
	err := firstErr
	errorMu.Unlock()
	if err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	if observe != nil {
		observe(PrepareProgress{Completed: completed, Total: len(p.clients), Workers: workers, Stage: PrepareStageReady})
	}
	return nil
}

// preparationUpdate carries worker counts to the Prepare caller, which owns
// observer invocation and joins workers even when that observer exits abnormally.
type preparationUpdate struct {
	stage                       PrepareStage
	activeDelta, completedDelta int
}

func (p *Pool) runPreparationWorkers(workerCtx context.Context, workers int, next *atomic.Int64, report func(PrepareStage, int, int), recordError func(error)) {
	var wg sync.WaitGroup
	wg.Add(workers)
	for range workers {
		go func() {
			defer wg.Done()
			for {
				if workerCtx.Err() != nil {
					return
				}
				i := int(next.Add(1) - 1)
				if i >= len(p.clients) {
					return
				}
				report(PrepareStageSSH, 1, 0)
				if err := p.masters[i].prepare(workerCtx); err != nil {
					recordError(err)
					report(PrepareStageSSH, -1, 0)
					return
				}
				report(PrepareStageProtocol, 0, 0)
				if err := p.clients[i].Prepare(workerCtx); err != nil {
					recordError(err)
					report(PrepareStageProtocol, -1, 0)
					return
				}
				report(PrepareStageProtocol, -1, 1)
			}
		}()
	}
	wg.Wait()
}

func (p *Pool) preparationWorkers() int {
	if p.endpoint == nil {
		return 1
	}
	return min(4, len(p.clients))
}

// MarshalJSON exposes operational metadata only; credentials remain available explicitly on the options.
func (o PoolOptions) MarshalJSON() ([]byte, error) {
	return json.Marshal(struct {
		Root, Directory, WorkerPath string
		Parallel                    int
	}{safeOptionURL(o.Root), o.Directory, o.WorkerPath, o.Parallel})
}
func (o PoolOptions) String() string { b, _ := o.MarshalJSON(); return "PoolOptions" + string(b) }

// GoString formats operational metadata without credentials.
func (o PoolOptions) GoString() string { return o.String() }

func safeOptionURL(raw string) string {
	if !strings.Contains(raw, "://") {
		return raw
	}
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "ssh" || u.Host == "" {
		return "[invalid URL]"
	}
	return u.Scheme + "://" + u.Host
}

func (p *Pool) closeLocked() error {
	if p.cleaned {
		return p.closeErr
	}
	if !p.closed {
		p.closed = true
		close(p.stop)
	}
	var err error
	for _, client := range p.clients {
		err = errors.Join(err, client.Close())
	}
	for _, master := range p.masters {
		err = errors.Join(err, master.close())
	}
	p.closeErr = err
	p.cleaned = true
	close(p.closeDone)
	return err
}

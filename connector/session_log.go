package connector

import (
	"errors"
	"io"
	"slices"
	"strings"
	"sync"

	expect "github.com/gatework/go-expect"
	"github.com/gatework/net-connector/internal/terminal"
	"github.com/gatework/net-connector/internal/textcodec"
)

type logWriter struct {
	mu                 sync.Mutex
	target             io.Writer
	level              LogLevel
	host, encoding     string
	line               strings.Builder
	redactor, rendered *expect.Redactor
	renderer           *terminal.Renderer
	secrets            []string
	paused             bool
	count              func(int)
}
type writerFunc func([]byte) (int, error)

func (f writerFunc) Write(p []byte) (int, error) { return f(p) }
func (l *logWriter) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.count != nil {
		l.count(len(p))
	}
	if l.paused || l.target == nil || l.level != "" && l.level != LogDebug {
		return len(p), nil
	}
	if l.redactor == nil {
		return 0, errors.New("connector: missing log redactor")
	}
	if _, e := l.renderer.Write(l.redactor.Append(p)); e != nil {
		return 0, e
	}
	return len(p), nil
}
func (l *logWriter) scope(secrets []string, paused bool) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if e := l.finishLocked(); e != nil {
		return e
	}
	return l.startLocked(secrets, paused)
}
func (l *logWriter) startLocked(secrets []string, paused bool) error {
	l.secrets = slices.Clone(secrets)
	l.paused = paused
	if paused || l.target == nil || l.level != "" && l.level != LogDebug {
		return nil
	}
	var e error
	l.redactor, e = expect.NewRedactor(textcodec.SecretVariants(secrets, l.encoding), "[REDACTED]")
	if e != nil {
		return e
	}
	l.rendered, e = expect.NewRedactor(secrets, "[REDACTED]")
	if e != nil {
		return e
	}
	l.newRendererLocked()
	return nil
}
func (l *logWriter) newRendererLocked() {
	l.renderer = terminal.New(writerFunc(func(p []byte) (int, error) {
		if e := l.emit(l.rendered.Append(p)); e != nil {
			return 0, e
		}
		return len(p), nil
	}), 32<<20, false)
	l.renderer.Encoding = l.encoding
}
func (l *logWriter) push(secrets []string, paused bool) (func() error, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	oldSecrets := slices.Clone(l.secrets)
	oldPaused := l.paused
	if e := l.finishLocked(); e != nil {
		return nil, e
	}
	if e := l.startLocked(secrets, paused); e != nil {
		return nil, e
	}
	return func() error { return l.scope(oldSecrets, oldPaused) }, nil
}
func (l *logWriter) protectReply(secret string) error {
	if e := l.addSecret(secret); e != nil {
		return e
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	if e := l.finishLocked(); e != nil {
		return e
	}
	return l.startLocked(l.secrets, true)
}
func (l *logWriter) addSecret(secret string) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if secret == "" {
		return nil
	}
	l.secrets = append(l.secrets, secret)
	if l.redactor == nil {
		return l.startLocked(l.secrets, l.paused)
	}
	tail, e := l.redactor.SetSecrets(textcodec.SecretVariants(l.secrets, l.encoding))
	if e != nil {
		return e
	}
	// Update rendered protection before passing any newly released raw suffix.
	visible, e := l.rendered.SetSecrets(l.secrets)
	if e != nil {
		return e
	}
	if l.paused {
		return nil
	}
	if e = l.emit(visible); e != nil {
		return e
	}
	_, e = l.renderer.Write(tail)
	return e
}
func (l *logWriter) emit(p []byte) error {
	if l.target == nil || len(p) == 0 {
		return nil
	}
	if l.level == "" {
		return l.writeTarget(p)
	}
	if l.level != LogDebug {
		return nil
	}
	for _, b := range p {
		if b == '\n' {
			if err := l.flushLine(); err != nil {
				return err
			}
		} else {
			l.line.WriteByte(b)
		}
	}
	return nil
}
func (l *logWriter) finishLocked() error {
	if l.redactor == nil {
		return nil
	}
	defer func() { l.redactor = nil; l.renderer = nil; l.rendered = nil }()
	return l.flushLocked()
}
func (l *logWriter) flushLocked() error {
	if l.redactor == nil || l.paused || l.target == nil || l.level != "" && l.level != LogDebug {
		return nil
	}
	if _, err := l.renderer.Write(l.redactor.Finish()); err != nil {
		return err
	}
	if err := l.renderer.Finish(); err != nil {
		return err
	}
	if err := l.emit(l.rendered.Finish()); err != nil {
		return err
	}
	if err := l.flushLine(); err != nil {
		return err
	}
	l.newRendererLocked()
	return nil
}

func (l *logWriter) finish() error { l.mu.Lock(); defer l.mu.Unlock(); return l.finishLocked() }

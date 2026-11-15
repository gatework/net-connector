package progress

import (
	"context"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"

	"golang.org/x/term"

	"github.com/gatework/net-connector/internal/display"
)

func (p *Reporter) clearLocked() {
	if p.rows == 0 {
		return
	}
	_, height := 80, 24
	if f, ok := p.out.(*os.File); ok {
		if w, h, e := term.GetSize(int(f.Fd())); e == nil && w > 1 && h > 1 {
			height = h
		}
	}
	start := max(1, height-p.rows+1)
	_ = p.writeRawLocked("\x1b7")
	for row := start; row <= height; row++ {
		_ = p.writeRawLocked(fmt.Sprintf("\x1b[%d;1H\r\x1b[2K", row))
	}
	_ = p.writeRawLocked("\x1b8")
	p.rows = 0
	p.refreshing = false
	p.panelStart = 0
	p.panelTitle = ""
}

// reservePanelRows keeps terminal line echoes and ordinary output from scrolling
// the live panel off the bottom of the screen. The full-screen region is restored
// when the reporter stops.
func (p *Reporter) reservePanelRowsLocked(height, rows int) {
	if !p.tty || rows == 0 || (p.scrollRegion && p.scrollHeight == height && p.scrollRows == rows) {
		return
	}
	bottom := max(1, height-rows)
	sequence := "\x1b7"
	if p.scrollRegion {
		sequence += "\x1b[r"
	}
	sequence += fmt.Sprintf("\x1b[1;%dr\x1b8", bottom)
	if p.writeRawLocked(sequence) == nil {
		p.scrollRegion = true
		p.scrollHeight = height
		p.scrollRows = rows
	}
}

func (p *Reporter) restoreScrollRegionLocked() {
	if !p.scrollRegion {
		return
	}
	if p.writeRawLocked("\x1b7\x1b[r\x1b8") == nil {
		p.scrollRegion = false
		p.scrollHeight, p.scrollRows = 0, 0
	}
}

func (p *Reporter) renderLocked(force bool) {
	if !p.tty || p.stopped || p.paused > 0 || p.finished || p.err != nil {
		return
	}
	if !force && time.Since(p.lastRender) < 200*time.Millisecond {
		return
	}
	width, height := 80, 24
	if f, ok := p.out.(*os.File); ok {
		if w, h, err := term.GetSize(int(f.Fd())); err == nil && w > 1 {
			width, height = w, h
		}
	}
	oldestHost := ""
	var oldest task
	for host, t := range p.active {
		if oldestHost == "" || t.started.Before(oldest.started) {
			oldestHost, oldest = host, t
		}
	}
	percent := 0.
	if p.total > 0 {
		percent = 100 * float64(p.completed) / float64(p.total)
	}
	progressTitle := strings.TrimSuffix(display.Section(p.out, "当前进度"), "\n")
	lines := []string{progressTitle, fmt.Sprintf("%s：%d/%d（%.1f%%）", p.phase, p.completed, p.total, percent), fmt.Sprintf("成功 %d；失败 %d；跳过 %d；待核实 %d", p.succeeded, p.failed, p.skipped, p.pending), p.activityLocked(), fmt.Sprintf("已用 %.1f 秒", time.Since(p.started).Seconds())}
	if p.latestFailure != "" {
		lines = []string{lines[0], lines[1], lines[2], "最近异常：" + p.latestFailure, lines[3], lines[4]}
	}
	elapsedIndex := len(lines) - 1
	if oldestHost != "" {
		lines[elapsedIndex] += fmt.Sprintf("；最长阶段 %s %s %.0f 秒", oldestHost, oldest.stage.label(), time.Since(oldest.started).Seconds())
	}
	if p.verbose {
		lines = append(lines, p.detail)
	}
	if height <= 8 {
		status := fmt.Sprintf("失败 %d；活动 %d；已用 %.0f 秒", p.failed, len(p.active), time.Since(p.started).Seconds())
		if p.latestFailure != "" {
			status += "；最近异常：" + p.latestFailure
		}
		lines = []string{progressTitle, lines[1], status}
	}
	start := max(1, height-len(lines)+1)
	samePanel := p.refreshing && p.rows == len(lines) && p.panelStart == start && p.panelTitle == progressTitle
	if !samePanel {
		p.clearLocked()
		p.reservePanelRowsLocked(height, len(lines))
	}
	_ = p.writeRawLocked("\x1b7")
	first := 0
	if samePanel {
		first = 1
	}
	for i := first; i < len(lines); i++ {
		line := lines[i]
		_ = p.writeRawLocked(fmt.Sprintf("\x1b[%d;1H\r\x1b[2K", start+i))
		clipped := display.Clip(line, width-1)
		_ = p.writeRawLocked(clipped)
	}
	_ = p.writeRawLocked("\x1b8")
	p.rows = len(lines)
	p.refreshing = true
	p.panelStart = start
	p.panelTitle = progressTitle
	p.lastRender = time.Now()
}

func (p *Reporter) tick() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.finished || p.err != nil || p.paused > 0 {
		return
	}
	if p.tty {
		p.renderLocked(true)
	} else {
		_ = p.writeLocked(fmt.Sprintf("等待中：%s；已用 %.1f 秒；%s", p.phase, time.Since(p.started).Seconds(), p.countsLocked()))
	}
}

// RunUpdates starts one heartbeat owned by the returned idempotent stop function.
// Cancellation and stop both wake the goroutine; stop joins before returning.
func (p *Reporter) RunUpdates(ctx context.Context) func() {
	if p == nil || p.out == nil {
		return func() {}
	}
	stop, done := make(chan struct{}), make(chan struct{})
	var once sync.Once
	go func() { //nolint:gosec // after cancellation the panel keeps rendering the shutdown notice until stop
		defer close(done)
		ticker := time.NewTicker(p.interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				p.cancellingNotice()
				ctx = context.Background()
			case <-stop:
				return
			case <-ticker.C:
				p.tick()
			}
		}
	}()
	return func() {
		once.Do(func() { close(stop) })
		<-done
		p.mu.Lock()
		defer p.mu.Unlock()
		p.stopped = true
		p.clearLocked()
		p.restoreScrollRegionLocked()
	}
}

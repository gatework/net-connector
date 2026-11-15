// Package progress renders bounded, safe human progress independently of results.
package progress

import (
	"fmt"
	"io"
	"os"
	"strings"
	"sync"
	"time"

	"golang.org/x/term"

	"github.com/gatework/net-connector/internal/display"
)

type taskStage uint8

const (
	stageUnknown taskStage = iota
	stageConnect
	stageConfig
	stageTFTPCommand
	stageTFTPUpload
	stageArchiveVerification
	stageArchiveChannel
	stageNeighborCollection
)

func (s taskStage) label() string {
	switch s {
	case stageConnect:
		return "连接与登录"
	case stageConfig:
		return "采集配置"
	case stageTFTPCommand:
		return "TFTP 命令"
	case stageTFTPUpload:
		return "TFTP 上传"
	case stageArchiveVerification:
		return "归档核验"
	case stageArchiveChannel:
		return "准备归档通道"
	case stageNeighborCollection:
		return "采集邻居"
	default:
		return "未知阶段"
	}
}

type task struct {
	stage   taskStage
	started time.Time
}

// ArchivePreflight describes progress before any device task has started.
type ArchivePreflight struct {
	Stage                    string
	Completed, Total, Active int
	Workers                  int
	Group, Groups            int
}

// Reporter owns counters and its heartbeat, never the caller's writer.
// Writers must cooperate with their owner; no blocked write is abandoned.
type Reporter struct {
	mu                                                    sync.Mutex
	out                                                   io.Writer
	verbose, tty                                          bool
	interval                                              time.Duration
	started                                               time.Time
	phase                                                 string
	total, completed, succeeded, failed, skipped, pending int
	active                                                map[string]task
	err                                                   error
	finished                                              bool
	refreshing                                            bool
	rows, paused, panelStart                              int
	lastRender                                            time.Time
	scrollHeight, scrollRows                              int
	scrollRegion                                          bool
	detail                                                string
	panelTitle                                            string
	latestFailure                                         string
	workers                                               int
	stopped                                               bool
	mode                                                  string
	progressSection, warningSection                       bool
	cancelling                                            bool
	archivePreflight                                      *ArchivePreflight
}

// New creates a reporter that borrows out for the duration of the run.
func New(out io.Writer, verbose bool) *Reporter {
	p := &Reporter{out: out, verbose: verbose, interval: 5 * time.Second, started: time.Now(), active: make(map[string]task)}
	if f, ok := out.(*os.File); ok {
		p.tty = term.IsTerminal(int(f.Fd()))
		if os.Getenv("TERM") == "dumb" {
			p.tty = false
		}
		if p.tty {
			p.interval = 200 * time.Millisecond
		}
	}
	return p
}
func safeText(text string) string { return display.Text(text) }

// Notice serializes persistent diagnostics with the live panel.
func (p *Reporter) Notice(text string) error {
	if p == nil {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	err := p.writeLocked(text)
	p.renderLocked(true)
	return err
}

// Section clears the live panel before writing a persistent section heading.
func (p *Reporter) Section(title string) error {
	if p == nil {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.sectionLocked(title)
}

// Warning keeps exceptional diagnostics together above the live panel.
func (p *Reporter) Warning(text string) error {
	if p == nil {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.warningLocked()
	err := p.writeLocked(text)
	p.renderLocked(true)
	return err
}

// Pause clears the panel until the returned resume function is called.
func (p *Reporter) Pause() func() {
	if p == nil {
		return func() {}
	}
	p.mu.Lock()
	p.paused++
	p.clearLocked()
	p.mu.Unlock()
	var once sync.Once
	return func() { once.Do(func() { p.mu.Lock(); defer p.mu.Unlock(); p.paused--; p.renderLocked(true) }) }
}

// Phase displays the current operation phase.
func (p *Reporter) Phase(text string) error {
	if p == nil {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.phase = safeText(text)
	if !strings.Contains(p.phase, "预检") {
		p.archivePreflight = nil
	}
	if p.tty && p.paused == 0 {
		p.renderLocked(true)
		return p.err
	}
	return p.writeLocked(p.phase)
}

// Plan displays the inventory selection and worker budget.
func (p *Reporter) Plan(total, selected, workers int, mode string) error {
	if p == nil {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.mode = mode
	p.total = selected
	p.completed = 0
	p.succeeded = 0
	p.failed = 0
	p.skipped, p.pending = 0, 0
	p.active = make(map[string]task)
	p.archivePreflight = nil
	p.finished = false
	p.detail = ""
	p.progressSection, p.warningSection, p.cancelling = false, false, false
	p.started = time.Now()
	p.workers = workers
	if p.phase == "" || p.phase == "正在读取设备清单" || strings.Contains(p.phase, "正在生成计划") {
		p.phase = "执行设备任务"
		switch mode {
		case "backup":
			p.phase = "备份配置"
		case "topology":
			p.phase = "邻居接口描述"
		case "tftp":
			p.phase = "TFTP 备份"
		}
	}
	_ = p.sectionLocked("任务计划")
	return p.writeLocked(fmt.Sprintf("计划：清单 %d 台；选中 %d 台；跳过 %d 台；并发 %d", total, selected, max(total-selected, 0), workers))
}

// ArchivePreflight updates archive readiness independently from device completion counts.
func (p *Reporter) ArchivePreflight(status ArchivePreflight) error {
	if p == nil {
		return nil
	}
	status.Total = max(status.Total, 0)
	status.Completed = min(max(status.Completed, 0), status.Total)
	status.Active = max(status.Active, 0)
	status.Workers = max(status.Workers, 0)
	status.Group = max(status.Group, 0)
	status.Groups = max(status.Groups, 0)
	if status.Stage == "" {
		status.Stage = "正在预检 TFTP 归档服务"
	}
	status.Stage = safeText(status.Stage)
	p.mu.Lock()
	defer p.mu.Unlock()
	previous := p.archivePreflight
	p.archivePreflight = &status
	p.phase = status.Stage
	if p.tty && p.paused == 0 {
		p.renderLocked(true)
		return p.err
	}
	if previous == nil || previous.Stage != status.Stage || previous.Completed != status.Completed || previous.Group != status.Group || status.Completed == status.Total {
		_ = p.writeLocked(p.archivePreflightLineLocked())
	}
	return p.err
}

// BeginPhase resets device counters for a workflow subphase without printing a second task plan.
func (p *Reporter) BeginPhase(total, workers int) error {
	if p == nil {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.total = max(total, 0)
	p.completed, p.succeeded, p.failed, p.skipped, p.pending = 0, 0, 0, 0, 0
	p.active = make(map[string]task)
	p.archivePreflight = nil
	p.detail = ""
	p.cancelling = false
	p.workers = workers
	p.renderLocked(true)
	return p.err
}

// Start records that a device began execution.
func (p *Reporter) Start(host, vendor string) error {
	if p == nil {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	p.archivePreflight = nil
	if !p.progressSection {
		p.progressSection = true
		if !p.tty {
			_ = p.sectionLocked("执行进度")
		}
		switch p.mode {
		case "tftp":
			p.phase = "TFTP 备份"
		case "topology":
			p.phase = "邻居接口描述"
		default:
			p.phase = "备份配置"
		}
	}
	p.active[host] = task{stage: stageConnect, started: time.Now()}
	if p.verbose {
		p.detail = fmt.Sprintf("[%s] 正在连接与登录（%s）", safeText(host), safeText(vendor))
	} else {
		p.detail = ""
	}
	p.renderLocked(false)
	return p.err
}

// Event updates the named device stage with a safe status.
func (p *Reporter) Event(host, name, status string) error {
	if p == nil {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	item, ok := p.active[host]
	if !ok {
		return nil
	}
	item, message, known := p.eventStage(item, name, status)
	if !known {
		return nil
	}
	if name == "command_start" || item.stage != p.active[host].stage {
		item.started = time.Now()
	}
	p.active[host] = item
	if p.verbose {
		p.detail = fmt.Sprintf("[%s] %s", safeText(host), message)
	} else {
		p.detail = ""
	}
	p.renderLocked(false)
	return p.err
}

// Stage accepts only bounded workflow metadata, never command text.
func (p *Reporter) Stage(host, stage string) error {
	if p == nil {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	item, ok := p.active[host]
	if !ok {
		return p.err
	}
	var next taskStage
	switch stage {
	case "upload":
		next = stageTFTPUpload
	case "archive":
		next = stageArchiveVerification
	default:
		return p.err
	}
	if item.stage != next {
		item.started = time.Now()
	}
	item.stage = next
	p.active[host] = item
	p.renderLocked(false)
	return p.err
}

// Outcome records a finished device. status is the uniform device status
// (succeeded, partial, failed, interrupted, stopped); outcome is the
// operation-specific result shown to the operator, such as "backed_up".
func (p *Reporter) Outcome(host, status, outcome, errorCode string, duration time.Duration) error {
	if p == nil {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if _, active := p.active[host]; !active {
		return p.err
	}
	delete(p.active, host)
	p.completed++
	switch status {
	case "succeeded":
		p.succeeded++
	case "stopped":
		p.skipped++
	case "partial", "interrupted":
		p.pending++
	default:
		p.failed++
	}
	isFailure := status == "failed" || status == "partial"
	if isFailure {
		label := status
		if outcome != "" {
			label = outcome
		}
		message := display.Status(label)
		if errorCode != "" {
			message += "；" + display.Error(errorCode)
		}
		p.warningLocked()
		p.latestFailure = fmt.Sprintf("[%s] %s", safeText(host), message)
		_ = p.writeLocked(fmt.Sprintf("[%s] %s；耗时 %.1f 秒", safeText(host), message, duration.Seconds()))
	}
	p.renderLocked(isFailure)
	return p.err
}

// Finish stops the activity display and returns any output failure.
func (p *Reporter) Finish() error {
	if p == nil {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.finished {
		return p.err
	}
	p.finished = true
	p.clearLocked()
	p.restoreScrollRegionLocked()
	if p.err != nil {
		return p.err
	}
	_ = p.writeLocked(fmt.Sprintf("总耗时 %.1f 秒", time.Since(p.started).Seconds()))
	return p.err
}

// Err returns the first progress output failure.
func (p *Reporter) Err() error {
	if p == nil {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.err
}
func (p *Reporter) writeLocked(text string) error {
	p.clearLocked()
	return p.writeRawLocked(safeText(text) + "\n")
}

func (p *Reporter) sectionLocked(title string) error {
	p.clearLocked()
	return p.writeRawLocked(display.Section(p.out, title))
}
func (p *Reporter) warningLocked() {
	if !p.warningSection {
		_ = p.sectionLocked("异常与警告")
		p.warningSection = true
	}
}

func (p *Reporter) writeRawLocked(text string) error {
	if p.err != nil || p.out == nil {
		return p.err
	}
	n, err := io.WriteString(p.out, text)
	if err == nil && n != len(text) {
		err = io.ErrShortWrite
	}
	p.err = err
	return err
}
func (p *Reporter) archivePreflightLineLocked() string {
	server := ""
	if p.archivePreflight.Group > 0 && p.archivePreflight.Groups > 0 {
		server = fmt.Sprintf("归档服务器 %d/%d；", p.archivePreflight.Group, p.archivePreflight.Groups)
	}
	return fmt.Sprintf("%s；%s归档预检 %d/%d；活动 %d；预检并发 %d/%d；设备任务尚未开始 %d/%d；设备并发 %d", p.archivePreflight.Stage, server, p.archivePreflight.Completed, p.archivePreflight.Total, p.archivePreflight.Active, p.archivePreflight.Active, p.archivePreflight.Workers, p.completed, p.total, p.workers)
}
func (p *Reporter) activityLocked() string {
	if p.archivePreflight != nil {
		return p.archivePreflightLineLocked()
	}
	login, operation, upload, archive, archiveChannel := 0, 0, 0, 0, 0
	for _, t := range p.active {
		switch t.stage {
		case stageConnect:
			login++
		case stageArchiveChannel:
			archiveChannel++
		case stageTFTPUpload:
			upload++
		case stageArchiveVerification:
			archive++
		case stageTFTPCommand:
			operation++
		default:
			operation++
		}
	}
	queued := max(p.total-p.completed-len(p.active), 0)
	if p.cancelling {
		queued = 0
	}
	if p.mode == "tftp" {
		return fmt.Sprintf("登录 %d；归档通道 %d；上传 %d；归档 %d；设备命令 %d；排队 %d；并发 %d", login, archiveChannel, upload, archive, operation, queued, p.workers)
	}
	if p.mode == "topology" {
		return fmt.Sprintf("登录 %d；邻居采集 %d；排队 %d；并发 %d", login, operation+archive, queued, p.workers)
	}
	return fmt.Sprintf("登录 %d；配置采集 %d；排队 %d；并发 %d", login, operation+archive, queued, p.workers)
}
func (p *Reporter) countsLocked() string {
	return fmt.Sprintf("已完成 %d/%d；成功 %d；失败 %d；跳过 %d；待核实 %d；%s", p.completed, p.total, p.succeeded, p.failed, p.skipped, p.pending, p.activityLocked())
}

func (p *Reporter) cancellingNotice() {
	if p == nil {
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.finished || p.stopped || p.err != nil {
		return
	}
	p.cancelling = true
	p.phase = "正在停止未完成任务"
	if p.tty {
		p.renderLocked(true)
	} else if p.paused == 0 {
		_ = p.writeLocked(fmt.Sprintf("%s；%s", p.phase, p.countsLocked()))
	}
}

func (p *Reporter) eventStage(item task, name, status string) (task, string, bool) {
	var message string
	switch name {
	case "connect":
		item.stage = stageConnect
		message = "正在连接与登录"
	case "login_complete":
		if status == "ok" {
			switch p.mode {
			case "tftp":
				item.stage = stageArchiveChannel
				message = "登录成功，正在准备归档通道"
			case "topology":
				item.stage = stageNeighborCollection
				message = "登录成功，正在采集邻居"
			default:
				item.stage = stageConfig
				message = "登录成功，正在采集配置"
			}
		} else {
			message = "登录未完成"
		}
	case "command_start":
		switch p.mode {
		case "tftp":
			// The workflow stage is more precise than the generic session
			// event. Keep upload/archive accounting intact while the command
			// observer reports the device operation.
			if item.stage != stageTFTPUpload && item.stage != stageArchiveVerification {
				item.stage = stageTFTPCommand
			}
			message = "正在执行 TFTP 设备操作"
		case "topology":
			item.stage = stageNeighborCollection
			message = "正在采集邻居"
		default:
			item.stage = stageConfig
			message = "正在采集，等待设备响应"
		}
	case "command_complete":
		if p.mode == "tftp" && status == "response_received" {
			message = "TFTP 命令响应已接收"
		} else if p.mode == "tftp" && status == "failed" {
			message = "TFTP 命令执行失败"
		} else if p.mode == "tftp" {
			message = "TFTP 命令结果未确认"
		} else if status == "response_received" {
			message = "命令响应已接收"
		} else if status == "failed" {
			message = "命令执行失败"
		} else {
			message = "命令结果未确认"
		}
	case "operation_complete":
		switch status {
		case "completed":
			message = "设备脚本执行完成"
		case "failed":
			message = "设备脚本执行失败"
		default:
			message = "设备脚本完成状态未确认"
		}
	case "connect_failed":
		message = "连接失败"
	default:
		return item, "", false
	}
	return item, message, true
}

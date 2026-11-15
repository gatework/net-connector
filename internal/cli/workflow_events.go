package cli

import (
	"errors"
	"fmt"

	"github.com/gatework/net-connector/archive"
	"github.com/gatework/net-connector/internal/display"
	"github.com/gatework/net-connector/internal/progress"
	"github.com/gatework/net-connector/internal/workflow"
)

func workflowObserver(p *progress.Reporter) workflow.Observer {
	if p == nil {
		return nil
	}
	return func(event workflow.Event) error {
		switch e := event.(type) {
		case workflow.PlanEvent:
			return p.Plan(e.Total, e.Selected, e.Workers, e.Mode)
		case workflow.StartEvent:
			return p.Start(e.Host, e.Platform)
		case workflow.SessionEvent:
			return p.Event(e.Host, e.Name, e.Status)
		case workflow.OutcomeEvent:
			err := p.Outcome(e.Host, string(e.Status), string(e.Outcome), e.ErrorCode, e.Duration)
			if e.TextWarningBytes > 0 {
				err = errors.Join(err, p.Warning(fmt.Sprintf("[%s] %s", e.Host, backupProgress(e))))
			}
			return err
		case workflow.TransferStageEvent:
			return p.Stage(e.Host, e.Stage)
		case workflow.PhaseEvent:
			switch e.Phase {
			case workflow.PhaseArchivePreflight:
				return p.Phase("正在预检 TFTP 归档服务（SSH、归档程序及目录权限）")
			case workflow.PhaseTransfer:
				return p.Phase(fmt.Sprintf("正在执行 TFTP 备份（上传上限 %.0f 秒）", e.Timeout.Seconds()))
			case workflow.PhaseTopologyPlan:
				return p.Phase("正在保存拓扑计划")
			case workflow.PhaseTopologyApply:
				return p.Phase("重新核验并应用拓扑计划")
			}
		case workflow.ArchivePreflightEvent:
			return p.ArchivePreflight(progress.ArchivePreflight{
				Stage: archivePreflightLabel(e.Progress.Stage), Completed: e.Progress.Completed,
				Total: e.Progress.Total, Active: e.Progress.Active, Workers: e.Progress.Workers,
				Group: e.Group, Groups: e.Groups,
			})
		case workflow.ArchiveReadyEvent:
			return p.Notice("TFTP 服务器 " + e.Server + "；归档目录：" + e.Directory)
		case workflow.BeginPhaseEvent:
			return p.BeginPhase(e.Total, e.Workers)
		case workflow.FinishedEvent:
			return p.Finish()
		}
		return nil
	}
}

func archivePreflightLabel(stage archive.PrepareStage) string {
	switch stage {
	case archive.PrepareStageSSH:
		return "正在连接 TFTP 归档服务器 SSH"
	case archive.PrepareStageProtocol:
		return "正在验证归档程序与目录权限"
	case archive.PrepareStageReady:
		return "TFTP 归档预检完成"
	default:
		return "正在预检 TFTP 归档服务"
	}
}

func backupProgress(out workflow.OutcomeEvent) string {
	label := string(out.Status)
	if out.Outcome != "" {
		label = string(out.Outcome)
	}
	text := display.Status(label)
	if out.TextWarningBytes > 0 {
		text += fmt.Sprintf("（文本编码告警：%d 个字节；%s）", out.TextWarningBytes,
			display.SourceState(out.SourceCommitted, out.SourceVerified))
	}
	if out.ErrorCode != "" {
		text += "；" + display.Error(out.ErrorCode)
	}
	return text
}

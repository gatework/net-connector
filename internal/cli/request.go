package cli

import "github.com/gatework/net-connector/internal/workflow"

type requestKind uint8

const (
	requestInvalid requestKind = iota
	requestDefaults
	requestInitialize
	requestShow
	requestCheck
	requestExport
	requestInventory
	requestBackupPlan
	requestBackupRun
	requestTFTPPlan
	requestTFTPRun
	requestTopologyPlan
	requestTopologyDiscover
	requestTopologyApply
	requestDeployPlan
	requestDeployRun
	requestExecPlan
	requestExecRun
	requestFactsPlan
	requestFactsRun
	requestRemotePlan
	requestRemoteRun
	requestDiff
)

// commandRequest is the validated action selected by the command tree. Parsed
// flags stay in options; this value owns execution intent and topology options.
// No later config load or presentation step can turn a plan into an apply.
type commandRequest struct {
	kind     requestKind
	topology workflow.TopologyOptions
	// useCase is the business operation of a pipeline command; nil for local
	// configuration commands.
	useCase useCase
}

// runKinds maps a mode/action pair to its pipeline request.
var runKinds = map[string]requestKind{
	"backup/plan": requestBackupPlan, "backup/run": requestBackupRun,
	"tftp/plan": requestTFTPPlan, "tftp/run": requestTFTPRun,
	"topology/plan": requestTopologyPlan, "topology/discover": requestTopologyDiscover, "topology/apply": requestTopologyApply,
	"deploy/plan": requestDeployPlan, "deploy/run": requestDeployRun,
	"remote/plan": requestRemotePlan, "remote/run": requestRemoteRun,
	"exec/plan": requestExecPlan, "exec/run": requestExecRun,
	"facts/plan": requestFactsPlan, "facts/run": requestFactsRun,
}

// newCommandRequest maps the mode and action to a request kind and use case.
func newCommandRequest(o options) (commandRequest, error) {
	if o.mode != "backup" && o.mode != "tftp" && o.mode != "topology" && o.mode != "deploy" && o.mode != "exec" && o.mode != "facts" && o.mode != "remote" {
		return commandRequest{}, newUsageError("用途无效，请查看 --for 选项")
	}
	request := commandRequest{}
	switch o.action {
	case "defaults":
		request.kind = requestDefaults
	case "init":
		request.kind = requestInitialize
	case "show":
		request.kind = requestShow
	case "check":
		request.kind = requestCheck
	case "diff":
		request.kind = requestDiff
	case "export":
		if o.mode != "backup" {
			return request, newUsageError("此用途不支持导出")
		}
		request.kind = requestExport
	case "inventory":
		request.kind = requestInventory
		request.topology = workflow.TopologyOptions{InventoryOnly: true, Limit: o.limit}
	case "plan", "run", "discover", "apply":
		request.kind = runKinds[o.mode+"/"+o.action]
		if o.mode == "topology" {
			request.topology = workflow.TopologyOptions{Limit: o.limit}
		}
	}
	if request.kind == requestInvalid {
		return request, newUsageError("此用途不支持所选操作")
	}
	request.useCase = request.newUseCase()
	return request, nil
}

// newUseCase maps a pipeline command to its business operation.
func (r commandRequest) newUseCase() useCase {
	switch r.kind { //nolint:exhaustive // This query intentionally selects a subset; remaining requests use the documented default.
	case requestInventory:
		return inventoryUseCase{}
	case requestBackupPlan, requestBackupRun:
		return backupUseCase{preview: r.kind == requestBackupPlan}
	case requestTFTPPlan, requestTFTPRun:
		return tftpUseCase{preview: r.kind == requestTFTPPlan}
	case requestDeployPlan, requestDeployRun:
		return &deployUseCase{preview: r.kind == requestDeployPlan}
	case requestRemotePlan, requestRemoteRun:
		return remoteUseCase{preview: r.kind == requestRemotePlan}
	case requestExecPlan, requestExecRun:
		return &execUseCase{preview: r.kind == requestExecPlan}
	case requestFactsPlan, requestFactsRun:
		return factsUseCase{preview: r.kind == requestFactsPlan}
	case requestTopologyPlan, requestTopologyDiscover, requestTopologyApply:
		return topologyUseCase{mode: r.topologyMode(), options: r.topology}
	default: // configuration requests and invalid input have no pipeline use case
		return nil
	}
}

func (r commandRequest) startsProgress() bool {
	switch r.kind { //nolint:exhaustive // This query intentionally selects a subset; remaining requests use the documented default.
	case requestDefaults, requestInitialize, requestShow, requestCheck, requestExport, requestDiff:
		return false
	default:
		return true
	}
}

func (r commandRequest) needsRunConfirmation() bool {
	return r.kind == requestBackupRun || r.kind == requestTFTPRun || r.kind == requestRemoteRun || r.kind == requestTopologyApply || r.kind == requestDeployRun
}

func (r commandRequest) topologyMode() string {
	switch r.kind { //nolint:exhaustive // This query intentionally selects a subset; remaining requests use the documented default.
	case requestInventory, requestTopologyPlan:
		return "plan"
	case requestTopologyDiscover:
		return "discover"
	case requestTopologyApply:
		return "apply"
	default:
		return ""
	}
}

/**
 * /admin/audit（Phase 7 骨架）。
 * 审计仪表盘（R10：ToolCallLog / PendingOperation / WorkflowRun / SignalLog；
 * 待 Phase 9 填充数据源 + workspace/时间/状态过滤）。
 */
export default function AdminAuditPage() {
	return (
		<section>
			<h1 className="text-2xl font-semibold mb-2">审计</h1>
			<p className="text-neutral-600">
				平台操作审计（工具调用 / 待确认操作 / 工作流运行 / 信号日志；待 Phase 9 填充）。
			</p>
		</section>
	);
}

/**
 * /admin/applications（Phase 7 骨架）。
 * 工作台创建申请审批队列（R7：pending 列表 + approve/reject；待 Phase 9 填充）。
 */
export default function AdminApplicationsPage() {
	return (
		<section>
			<h1 className="text-2xl font-semibold mb-2">申请审批</h1>
			<p className="text-neutral-600">
				工作台创建申请队列（待 Phase 9 填充：pending 列表、通过 / 拒绝）。
			</p>
		</section>
	);
}

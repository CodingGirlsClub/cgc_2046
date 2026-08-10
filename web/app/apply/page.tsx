/**
 * /apply（Phase 7 骨架，R6 / OQ1 独立 /apply 页）。
 * 已注册用户提交创建工作台申请（name / slug / purpose，申请人默认为 Owner）。
 * 表单与提交（走 WorkspaceApplication.create）待 Phase 9 填充数据源后接线。
 */
export default function ApplyPage() {
	return (
		<section className="mx-auto max-w-xl px-4 py-10">
			<h1 className="text-2xl font-semibold mb-2">申请创建工作台</h1>
			<p className="text-neutral-600 mb-6">
				填写你希望创建的工作台信息，提交后由平台管理员审批。审批通过后你将作为该工作台的
				Owner。
			</p>
			<p className="text-sm text-neutral-400">
				申请表单（工作台名称 / slug / 用途）待 Phase 9 填充。
			</p>
		</section>
	);
}

import type { Metadata } from "next";
import { getTranslations } from "next-intl/server";
import { pageAlternates } from "@/lib/seo";

/**
 * /privacy 隐私政策 + 个人信息处理规则（静态法务页，#210 U1）。
 *
 * 内容一字不差转写自两份源档：
 * - docs/合规上架/隐私政策.md（全文）
 * - docs/合规上架/个人信息处理规则.md（全文，作为末节附录——PIPL 要求
 *   处理规则公开即可，与隐私政策同页呈现，见 plan 设计决策）。
 * 法务文本变更时必须同步更新源档与本页（评审义务）。
 * 法律文本仅中文（CONTEXT.md D 决策）：en locale 同样渲染本中文内容，
 * 头注明示以中文版本为准。
 */
type PageProps = {
	params: Promise<{ locale: string }>;
};

export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
	const { locale } = await params;
	const t = await getTranslations({ locale, namespace: "legal.privacy" });
	return {
		title: t("title"),
		description: t("description"),
		alternates: pageAlternates("/privacy", locale),
	};
}

const cell = "border-b border-line py-2 pr-4 align-top text-sm leading-6 text-ink-2";

export default function PrivacyPage() {
	return (
		<main className="mx-auto max-w-3xl px-4 py-10">
			<h1 className="l-h1">CGC 平台隐私政策</h1>

			<div className="mt-4 space-y-1 rounded-large border border-line bg-card px-5 py-4 text-[12px] leading-5 text-ink-3">
				<p>生效日期 2026-09-01 ｜ 法律文本以中文版本为准（The Chinese version prevails）</p>
				<p>版本 v1.0（2026-08-20）｜ 运营者：CodingGirlsClub（「我们」）</p>
				<p>文本源档：docs/合规上架/隐私政策.md、docs/合规上架/个人信息处理规则.md</p>
			</div>

			<p className="mt-8 text-sm leading-7 text-ink-2">
				欢迎使用 CGC 平台（codingirlsclub.com，含微信/抖音/小红书小程序端，以下合称「本平台」）。本政策说明我们收集哪些个人信息、如何使用与保护、您拥有哪些权利。<strong>使用本平台即表示您已阅读并同意本政策。</strong>
			</p>

			<section className="mt-10">
				<h2 className="l-h3">1. 我们收集的信息</h2>

				<h3 className="l-h4 mt-6">1.1 您主动提供的信息</h3>
				<table className="mt-3 w-full border-collapse text-left">
					<thead>
						<tr className="border-b border-line text-[13px] font-medium text-ink-3">
							<th className="py-2 pr-4">信息</th>
							<th className="py-2 pr-4">场景</th>
							<th className="py-2">是否必填</th>
						</tr>
					</thead>
					<tbody>
						<tr>
							<td className={cell}>电子邮箱地址</td>
							<td className={cell}>注册、登录（邮箱+密码）、找回密码</td>
							<td className={cell}>网站端注册必填</td>
						</tr>
						<tr>
							<td className={cell}>密码</td>
							<td className={cell}>邮箱+密码登录（仅存储加密哈希，我们不存储明文密码）</td>
							<td className={cell}>该登录方式必填</td>
						</tr>
						<tr>
							<td className={cell}>手机号码</td>
							<td className={cell}>短信验证码登录；微信/抖音/小红书小程序手机号快捷登录（经平台授权组件，我们仅收到授权结果中的号码）</td>
							<td className={cell}>使用对应登录方式时必填</td>
						</tr>
						<tr>
							<td className={cell}>姓名/昵称（display_name）</td>
							<td className={cell}>个人资料展示</td>
							<td className={cell}>选填</td>
						</tr>
						<tr>
							<td className={cell}>报名理由、提交材料</td>
							<td className={cell}>报名活动/课程、申请赞助或讲者</td>
							<td className={cell}>对应业务必填</td>
						</tr>
						<tr>
							<td className={cell}>学习记录、作业产出</td>
							<td className={cell}>参与课程学习</td>
							<td className={cell}>业务过程产生</td>
						</tr>
					</tbody>
				</table>

				<h3 className="l-h4 mt-6">1.2 登录与身份关联信息</h3>
				<ul className="mt-3 list-disc space-y-2 pl-6 text-sm leading-7 text-ink-2">
					<li>第三方平台身份标识（openid/unionid）：您经微信（含扫码与小程序）、抖音、小红书登录时，平台返回的匿名标识，用于识别同一账号。</li>
					<li><strong>同一手机号在不同平台登录会归一到同一账号</strong>（跨平台归一）。</li>
					<li>平台会话密钥（session_key）仅在我们的服务端调用栈内使用，<strong>不进日志、不进数据库、不向任何端返回</strong>。</li>
				</ul>

				<h3 className="l-h4 mt-6">1.3 自动收集的信息</h3>
				<ul className="mt-3 list-disc space-y-2 pl-6 text-sm leading-7 text-ink-2">
					<li>登录凭证与令牌（用于维持登录态；网站登录态存于加密 Cookie，Agent 连接令牌可由您自主生成与撤销）。</li>
					<li>操作日志：平台记录必要的账户与操作事件（如报名提交、审批操作、工具调用审计），用于安全与争议追溯。</li>
					<li>网络信息：处理请求所必需的 IP 地址（用于安全防护与限流，如登录失败次数限制）。</li>
				</ul>
			</section>

			<section className="mt-10">
				<h2 className="l-h3">2. 我们如何使用信息</h2>
				<table className="mt-3 w-full border-collapse text-left">
					<thead>
						<tr className="border-b border-line text-[13px] font-medium text-ink-3">
							<th className="py-2 pr-4">目的</th>
							<th className="py-2">涉及信息</th>
						</tr>
					</thead>
					<tbody>
						<tr>
							<td className={cell}>账号创建与身份验证</td>
							<td className={cell}>邮箱、手机号、密码哈希、平台身份标识</td>
						</tr>
						<tr>
							<td className={cell}>报名与审批处理</td>
							<td className={cell}>报名表单内容、账号身份</td>
						</tr>
						<tr>
							<td className={cell}>通知送达</td>
							<td className={cell}>手机号（经平台订阅消息/短信）、邮箱（交易类邮件，如密码重置）——<strong>每次小程序订阅消息均需您主动授权，无授权不发送</strong></td>
						</tr>
						<tr>
							<td className={cell}>订单与支付</td>
							<td className={cell}>订单信息；支付由微信支付/支付宝处理，我们仅收到支付结果与必要对账信息（详见第 5 节）</td>
						</tr>
						<tr>
							<td className={cell}>课程学习服务</td>
							<td className={cell}>学习记录、作业产出</td>
						</tr>
						<tr>
							<td className={cell}>安全与反滥用</td>
							<td className={cell}>操作日志、IP（限流与异常行为防护）</td>
						</tr>
					</tbody>
				</table>
				<p className="mt-4 text-sm leading-7 text-ink-2"><strong>我们不做什么</strong>：不向其他用户公开您的手机号（审批人可见姓名/邮箱，不含手机号）；不用于营销推送；不出售个人信息；不做用户画像。</p>
			</section>

			<section className="mt-10">
				<h2 className="l-h3">3. 存储与保护</h2>
				<ul className="mt-3 list-disc space-y-2 pl-6 text-sm leading-7 text-ink-2">
					<li>密码仅存储不可逆加密哈希；登录令牌可撤销、有数量上限。</li>
					<li>手机号标记为敏感字段：不进入 API 响应、不进入日志——包括您本人在内的任何用户都无法通过接口读取手机号。</li>
					<li>全站强制 HTTPS 传输。</li>
					<li>手机号当前以可识别形态存储于数据库（用于跨平台账号归一），该方案已经过内部安全评审；后续版本将增加敏感操作二次校验。</li>
				</ul>
			</section>

			<section className="mt-10">
				<h2 className="l-h3">4. 存储期限</h2>
				<ul className="mt-3 list-disc space-y-2 pl-6 text-sm leading-7 text-ink-2">
					<li>账号信息：存续于账号有效期内。</li>
					<li>操作与审计日志：保留合理期限用于安全与合规追溯。</li>
					<li>注销：当前版本可退出登录停止使用；账号注销与数据删除入口将在后续版本提供（届时可通过客服渠道提交人工注销申请）。</li>
				</ul>
			</section>

			<section className="mt-10">
				<h2 className="l-h3">5. 第三方服务</h2>
				<p className="mt-3 text-sm leading-7 text-ink-2">本平台依赖以下第三方处理必要业务，各自受其隐私政策约束：</p>
				<table className="mt-3 w-full border-collapse text-left">
					<thead>
						<tr className="border-b border-line text-[13px] font-medium text-ink-3">
							<th className="py-2 pr-4">第三方</th>
							<th className="py-2 pr-4">用途</th>
							<th className="py-2">传输给它的信息</th>
						</tr>
					</thead>
					<tbody>
						<tr>
							<td className={cell}>腾讯云（境内）</td>
							<td className={cell}>服务器与数据库托管</td>
							<td className={cell}>业务数据存储</td>
						</tr>
						<tr>
							<td className={cell}>微信开放平台/微信支付</td>
							<td className={cell}>登录、订阅消息、支付</td>
							<td className={cell}>openid、订单与支付要素</td>
						</tr>
						<tr>
							<td className={cell}>支付宝</td>
							<td className={cell}>支付</td>
							<td className={cell}>订单与支付要素</td>
						</tr>
						<tr>
							<td className={cell}>抖音/小红书开放平台</td>
							<td className={cell}>小程序登录与订阅消息</td>
							<td className={cell}>openid</td>
						</tr>
						<tr>
							<td className={cell}>SendCloud</td>
							<td className={cell}>交易类邮件（密码重置等）与短信验证码</td>
							<td className={cell}>收件邮箱/手机号、验证码内容</td>
						</tr>
					</tbody>
				</table>
				<p className="mt-4 text-sm leading-7 text-ink-2">我们不会向上述之外的主体提供您的个人信息，法律法规要求的除外。</p>
			</section>

			<section className="mt-10">
				<h2 className="l-h3">6. 您的权利</h2>
				<ul className="mt-3 list-disc space-y-2 pl-6 text-sm leading-7 text-ink-2">
					<li><strong>查询与更正</strong>：个人资料页可查看/修改姓名、昵称、语言偏好。</li>
					<li><strong>撤回授权</strong>：小程序订阅消息按次授权，拒绝授权不影响业务本身（如报名）。</li>
					<li><strong>退出登录</strong>：「我的」页/账户菜单可退出登录，服务端撤销当前登录态。</li>
					<li><strong>撤销 Agent 连接令牌</strong>：MCP 页可随时撤销已生成的连接令牌。</li>
					<li><strong>删除</strong>：如需删除账号或特定个人信息，可发送邮件至 info@codingirlsclub.com 联系我们，我们将在核实身份后 15 个工作日内处理。</li>
				</ul>
			</section>

			<section className="mt-10">
				<h2 className="l-h3">7. 未成年人</h2>
				<p className="mt-3 text-sm leading-7 text-ink-2">本平台面向技术社区教育与协作，不面向不满 14 周岁的儿童收集个人信息。如您是未成年人，请在监护人指导下使用本平台。</p>
			</section>

			<section className="mt-10">
				<h2 className="l-h3">8. 政策变更</h2>
				<p className="mt-3 text-sm leading-7 text-ink-2">政策重大变更时我们将通过站内公告或登录通知告知。继续使用即视为接受变更后的政策。</p>
			</section>

			<section className="mt-10">
				<h2 className="l-h3">9. 联系我们</h2>
				<ul className="mt-3 list-disc space-y-2 pl-6 text-sm leading-7 text-ink-2">
					<li>网站端：页脚「联系我们」</li>
					<li>个人信息安全问题：info@codingirlsclub.com</li>
				</ul>
				<p className="mt-4 text-[13px] leading-6 text-ink-3">备案信息：京ICP备16008426号-2</p>
			</section>

			<section className="mt-16 border-t border-line pt-10">
				<h2 className="l-h2">附录：CGC 平台个人信息处理规则</h2>
				<p className="mt-3 text-[13px] leading-6 text-ink-3">依据《个人信息保护法》（PIPL）第十七条编制，与本平台《隐私政策》配套公开。版本 v1.0（2026-08-20）</p>

				<h3 className="l-h4 mt-8">处理者信息</h3>
				<ul className="mt-3 list-disc space-y-2 pl-6 text-sm leading-7 text-ink-2">
					<li>处理者名称：CodingGirlsClub（运营者）</li>
					<li>网站域名：codingirlsclub.com（含小程序端）</li>
				</ul>

				<h3 className="l-h4 mt-8">处理目的、方式、种类一览</h3>
				<table className="mt-3 w-full border-collapse text-left">
					<thead>
						<tr className="border-b border-line text-[13px] font-medium text-ink-3">
							<th className="py-2 pr-4">个人信息种类</th>
							<th className="py-2 pr-4">处理目的</th>
							<th className="py-2 pr-4">处理方式</th>
							<th className="py-2">存储期限</th>
						</tr>
					</thead>
					<tbody>
						<tr>
							<td className={cell}>电子邮箱</td>
							<td className={cell}>账号注册、登录、密码重置通知</td>
							<td className={cell}>存储、验证、发送交易邮件</td>
							<td className={cell}>账号存续期</td>
						</tr>
						<tr>
							<td className={cell}>密码（哈希）</td>
							<td className={cell}>身份验证</td>
							<td className={cell}>单向加密存储、比对</td>
							<td className={cell}>账号存续期</td>
						</tr>
						<tr>
							<td className={cell}>手机号码</td>
							<td className={cell}>短信登录、跨平台账号归一、订阅消息送达</td>
							<td className={cell}>存储（敏感字段管控，不出 API/日志）</td>
							<td className={cell}>账号存续期</td>
						</tr>
						<tr>
							<td className={cell}>姓名/昵称</td>
							<td className={cell}>个人资料展示、报名身份呈现</td>
							<td className={cell}>存储、授权范围内展示</td>
							<td className={cell}>账号存续期</td>
						</tr>
						<tr>
							<td className={cell}>第三方平台标识（openid/unionid）</td>
							<td className={cell}>第三方登录身份关联</td>
							<td className={cell}>存储、验证</td>
							<td className={cell}>账号存续期</td>
						</tr>
						<tr>
							<td className={cell}>报名/申请表单内容</td>
							<td className={cell}>活动报名、赞助与讲者申请的审批处理</td>
							<td className={cell}>存储、授权范围内展示</td>
							<td className={cell}>业务必要期限</td>
						</tr>
						<tr>
							<td className={cell}>学习记录与作业产出</td>
							<td className={cell}>课程学习服务与进度展示</td>
							<td className={cell}>存储</td>
							<td className={cell}>账号存续期</td>
						</tr>
						<tr>
							<td className={cell}>订单与支付结果信息</td>
							<td className={cell}>订单管理、对账、退款</td>
							<td className={cell}>存储（支付要素由支付机构处理）</td>
							<td className={cell}>法定与对账必要期限</td>
						</tr>
						<tr>
							<td className={cell}>操作与审计日志</td>
							<td className={cell}>安全防护、限流、争议追溯</td>
							<td className={cell}>自动记录</td>
							<td className={cell}>安全必要期限</td>
						</tr>
						<tr>
							<td className={cell}>IP 地址</td>
							<td className={cell}>安全限流（如登录失败限制）</td>
							<td className={cell}>瞬时处理、日志留存</td>
							<td className={cell}>安全必要期限</td>
						</tr>
					</tbody>
				</table>

				<h3 className="l-h4 mt-8">敏感个人信息说明</h3>
				<ul className="mt-3 list-disc space-y-2 pl-6 text-sm leading-7 text-ink-2">
					<li><strong>手机号</strong>：用于登录与账号归一。授权入口即告知：登录页明示「登录即表示你同意隐私授权说明」；小程序端经平台授权组件主动授权后我们方获得号码。手机号字段实施了不出接口、不出日志的技术管控。</li>
					<li>本平台不收集生物识别、宗教信仰、医疗健康、金融账户、行踪轨迹、不满十四周岁未成年人信息等其它敏感个人信息。</li>
				</ul>

				<h3 className="l-h4 mt-8">委托处理与对外提供</h3>
				<ul className="mt-3 list-disc space-y-2 pl-6 text-sm leading-7 text-ink-2">
					<li>见《隐私政策》第 5 节第三方服务表（腾讯云/微信/支付宝/抖音/小红书/SendCloud），均为履行服务所必需。</li>
					<li>除上述及法律法规要求外，我们不向任何第三方提供个人信息；<strong>不出售个人信息</strong>。</li>
				</ul>

				<h3 className="l-h4 mt-8">自动化决策</h3>
				<p className="mt-3 text-sm leading-7 text-ink-2">本平台不进行基于个人信息的自动化决策（不含定向推送、差异化定价）。</p>

				<h3 className="l-h4 mt-8">个人信息跨境</h3>
				<p className="mt-3 text-sm leading-7 text-ink-2">本平台服务器位于中华人民共和国境内，不进行跨境传输。</p>

				<h3 className="l-h4 mt-8">个人权利响应</h3>
				<p className="mt-3 text-sm leading-7 text-ink-2">查询、复制、更正、删除、撤回同意、注销账号：可通过站内「联系我们」或 info@codingirlsclub.com 提出，我们将在 15 个工作日内核实身份并响应。</p>

				<h3 className="l-h4 mt-8">安全事件响应</h3>
				<p className="mt-3 text-sm leading-7 text-ink-2">发生个人信息泄露等安全事件时，我们将依法采取补救措施，按规定告知监管部门与受影响用户。</p>
			</section>
		</main>
	);
}

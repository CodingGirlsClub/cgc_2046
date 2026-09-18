/**
 * 草图 Variant D（完整信息架构版）—— 按《专场合作方案》PPT/PDF 视觉复刻。
 * 相对初版 D 的新增（⭐）：十周年视觉刻度条 / 参与者 FAQ / 时间线 / 背书挂真链接 /
 * 示例命名胶囊 / 交付能力三列（P5）/ 六层价值阶梯（P7）/ 开放共创议题（P9）/
 * 留存位（公众号占位）/ Footer 主理人小字入口。
 * 色板取自 pptx slide XML 精确值。内容骨架 = 双入口 + 十周年=2¹⁰ + partners@ + CTA → /initiatives。
 * 草图定位：方向性低保真，只看结构/氛围/层级。
 */
import SiteHeader from "@/components/site-header";
import "../hs1024.css";

/** 声波柱高度沿 2 的幂（2³→2¹⁰ 对数感），呼应数字叙事体系 */
const WAVE = [8, 12, 16, 24, 32, 24, 48, 32, 64, 48, 80, 64, 100, 80, 64, 48, 32, 24];

const RHYTHM = [
	{ min: "15", t: "开场", d: "认识 Agent、认识同场伙伴——不写代码，先知道要做什么", tone: "pink" },
	{ min: "120", t: "动手", d: "Agent 自适应学习陪你跑，第一次亲手把想法变成能跑的作品", tone: "mint" },
	{ min: "30", t: "Demo", d: "人人上台展示自己的作品——带得走、发得出、跑得起来", tone: "solid" },
] as const;

const FAQ = [
	{
		q: "零基础真的能参加吗？",
		a: "能。这一场就是为「第一次」设计的：3 小时、Agent 自适应学习全程陪跑，不需要任何编程基础——结束的时候，你会带着一个自己亲手做出来、能运行的作品离开。",
	},
	{
		q: "69 元押金是怎么回事？怎么退？",
		a: "报名时缴纳 69 元押金，到场参加即全额退还；未到场不退——名额有限，押金是为了把位置留给真的会来的人。",
	},
	{
		q: "需要自带电脑吗？",
		a: "建议自带笔记本电脑（现场以实操为主）；具体场次的设备说明以报名页为准。", // ⚠️ 待运营口径确认
	},
	{
		q: "有年龄限制吗？",
		a: "有，参与者需年满 18 岁。",
	},
	{
		q: "怎么知道我所在的城市有没有场次？",
		a: "首批场次 2026.10.24 起陆续上线，全国 40+ 城滚动开放。到倡导活动页查看全部场次——开放报名的场次都会出现在那里。",
	},
];

const TIMELINE = [
	{ t: "2026.10.24 启动", d: "全国首场开课，campaign 正式开始", start: true },
	{ t: "首期 64 场", d: "首批场次集中交付" }, // 口径已裁决（2026-09-18）：首期 64 场
	{ t: "批次滚动", d: "在 40+ 城陆续开班，直至 1,024 场" },
];

const HISTORY = [
	{ v: "10 城", l: "覆盖城市" },
	{ v: "50+", l: "线下工作坊" },
	{ v: "17 所", l: "高校联动" },
	{ v: "4,000+", l: "学员" },
	{ v: "1,000+", l: "教练" },
	{ v: "2,000 万+", l: "总阅读量" },
];

const ENDORSE: Array<{ text: string; url?: string }> = [
	{ text: "ICSE CHASE 2021（IEEE）论文收录 ↗", url: "https://cmustrudel.github.io/papers/chase21code_camps.pdf" },
	{ text: "联合国开发计划署「科技与慈善」案例（2018）↗", url: "https://www.undp.org/zh/china/publications/kejiyucishankechixufazhanxingdongbaogao" },
	{ text: "共青团中央「伙伴计划」获奖" },
	{ text: "联合国妇女署 #科技遇见她# ↗", url: "https://www.linkedin.com/posts/undp-china_herstory-womenintech-%E7%A7%91%E6%8A%80%E9%81%87%E8%A7%81%E5%A5%B9-activity-6787232105513525248-w6vp" },
	{ text: "中国日报（2017）↗", url: "https://www.chinadaily.com.cn/china/2017-01/13/content_27943492.htm" },
	{ text: "环球时报 ↗", url: "https://www.globaltimes.cn/content/954372.shtml" },
	{ text: "CCTV（CGTN）↗", url: "https://news.cgtn.com/news/3d49544e31516a4d/share_p.html" },
	{ text: "果壳网" }, // 方案口径：无稳定链接，保留文字
	{ text: "学员的故事 ↗", url: "https://mp.weixin.qq.com/s/IfRSC8sA7THv-YPBa4_XAg" }, // ⚠️ 占位：文章标题与主人公待创始人补充
];

const PERKS = [
	{ t: "系列命名", d: "专场系列名含你的品牌——联名系列，非单场冠名" },
	{ t: "定制课程", d: "课程主题、案例、教学路径按你的产品定制，课程完成即你的内容资产" },
	{ t: "现场转化钩子", d: "现场注册你的账号 / 发放产品权益 / 作品存入你的平台——激活变成可数的转化数据" },
	{ t: "下场观察", d: "你的团队直接进现场，零基础用户的第一手反馈进你的产品 backlog" },
];

/** 志愿者三职位（宣传页只放一句话摘要，深读在申请页） */
const VOLUNTEER_ROLES = [
	{
		t: "场次主理人",
		en: "Event Moderator",
		one: "组织一场 3 小时工作坊的完整 owner——把它开到你的城市",
		fit: "适合：有场地或社群资源、每期能投入一个周末的组织者",
		featured: true,
	},
	{
		t: "教程研究员",
		en: "Tutor",
		one: "把课程写成可复用的教程与示例项目，让教学质量可持续复制",
		fit: "适合：会编程、能写作的程序员 · 远程参与",
	},
	{
		t: "活动教练",
		en: "Coach",
		one: "线下现场的教学支持——巡场答疑、陪学员跑通动手环节，不讲课",
		fit: "适合：用过 Agent coding 工具、愿意教学相长的人",
	},
];

const CAPS = [
	{ t: "课程研发", d: "3 小时科普工作坊常态开班；AI Agent 专业课程与你的团队共同研发（60-100 小时）" },
	{ t: "运营机器", d: "8 人开班（2³）/ 32 满班（2⁵）押金风控；40+ 城主理人 + 128 名（2⁷）志愿者；单场 SOP 标准交付" },
	{ t: "数据平台", d: "报名、押金、核销、学习记录全链路自有；每场数据回收，按赞助商维度出交付报告" },
];

const LADDER = [
	{ t: "定制课程", d: "一门按你的产品定制的课——教学 IP 归属双方约定，活动结束后长期产生价值" },
	{ t: "激活用户", d: "512-2,048 名付费参与者（本轮计划）：18 岁以上、付 69 元押金、3 小时实操出作品" },
	{ t: "数据与案例", d: "学员作品 demo 库；真实使用数据匿名回收；联合发布成本/效果报告" },
	{ t: "渠道网络", d: "40+ 城主理人与志愿者体系；17 所高校合作历史与兴趣社群招生通道" },
	{ t: "ESG 与品牌信任", d: "联合国背书的女性数字赋能叙事，可直接进入企业社会责任报告" },
	{ t: "全程曝光", d: "招生物料 / 社媒 / 媒体报道 / 收官影响力报告联名署名（主办方历史总阅读 2,000 万+，历史累计）" },
];

const OPENQS = [
	{ t: "联合比赛", d: "共同设立专场作品比赛——你的品牌冠名、共同出题、设奖金，优秀作品进入你的生态" },
	{ t: "公益延伸", d: "你想支持而尚未覆盖的学校 / 城市 / 山区，专场可以开过去，联合写入 ESG 叙事" },
	{ t: "其他共创", d: "奖学金、认证、人才通道……开放的题，一起设计" },
];

export default function VariantD() {
	return (
		<main className="hsd-root">
			<SiteHeader />

			{/* 封面复刻：玫红大圆角卡片 */}
			<div className="hsd-hero-wrap">
				<div className="hsd-container">
					<section className="hsd-hero" aria-labelledby="hsd-hero-t">
						<p className="hsd-hero__eyebrow">CODING GIRLS CLUB 程序媛汇 · 十周年 CAMPAIGN</p>
						<span className="hsd-hero__slot">CGC × 你的品牌</span>
						<h1 className="hsd-hero__title" id="hsd-hero-t">Hacker Start 1024</h1>
						<p className="hsd-hero__sub">让普通人第一次亲手用 Agent 做出能跑的作品</p>
						<p className="hsd-hero__nums">
							<span>全国 <b>1,024</b> 场（<span className="hsd-pow">2<sup>10</sup></span>）</span>
							<span>2026.10.24 启动（<span className="hsd-pow">2<sup>0</sup></span>）</span>
							<span><b>16</b> 个品牌专场席位（<span className="hsd-pow">2<sup>4</sup></span>）</span>
						</p>
						<div className="hsd-hero__cta">
							<a href="#hsd-join" className="hsd-cta--white">我要参加</a>
							<a href="#hsd-host" className="hsd-cta--outline">成为志愿者</a>
							<a href="#hsd-brand" className="hsd-cta--outline">品牌合作</a>
						</div>
						<div className="hsd-wave" aria-hidden="true">
							{WAVE.map((h, i) => (
								<i key={i} style={{ height: `${h}%` }} />
							))}
						</div>
					</section>
					<div className="hsd-hero-foot">
						<div className="hsd-dots" aria-hidden="true">
							<i /><i /><i /><i />
						</div>
						{/* ⭐ 十周年视觉刻度条 */}
						<div className="hsd-scale" role="img" aria-label="2016 年成立，十年积累，2026 年启动 1,024 场">
							<span className="hsd-scale__tick">2016 · 成立</span>
							<span className="hsd-scale__rail">
								<span className="hsd-scale__fill" />
								<span className="hsd-scale__dot" />
								<span className="hsd-scale__now">第 10 年</span>
							</span>
							<span className="hsd-scale__tick hsd-scale__tick--end">2026 · <span className="hsd-pow">2<sup>10</sup></span>＝1,024 场</span>
						</div>
						<p className="hsd-hero-hook">
							2016 年成立，今年正好第 <b>10</b> 年 —— 所以是 <b>2<sup>10</sup> = 1,024</b> 场。
						</p>
					</div>
				</div>
			</div>

			{/* 为什么是现在 */}
			<section className="hsd-section" aria-labelledby="hsd-why-t">
				<div className="hsd-container">
					<div className="hsd-badge-row">
						<span className="hsd-badge">为什么是现在</span>
						<span className="hsd-badge-label">Why Now</span>
					</div>
					<h2 className="hsd-title" id="hsd-why-t">
						Agent 已经过了能力拐点，<em>缺的是普通人敢不敢开始</em>
					</h2>
					<p className="hsd-lead">
						Agent coding 已经能干活了，瓶颈变成了「普通人敢不敢开始、第一次有没有人陪跑」。
						所有厂商的自然流量都是开发者；零基础普通人的第一次，市场上没有现成通道。
						Hacker Start 1024 就是这条通道：3 小时一场 · 8-32 人小班 · Agent 自适应学习 ·
						69 元押金（到场退）——把「第一次亲手做出可运行的作品」变成可交付的东西。
					</p>
				</div>
			</section>

			{/* 我要参加 */}
			<section className="hsd-section" id="hsd-join" aria-labelledby="hsd-join-t">
				<div className="hsd-container">
					<div className="hsd-badge-row">
						<span className="hsd-badge">我要参加</span>
						<span className="hsd-badge-label">Join a Session</span>
					</div>
					<h2 className="hsd-title" id="hsd-join-t">
						3 小时，从零到<em>上台 demo</em>
					</h2>
					<div className="hsd-formula">
						{RHYTHM.map((r) => (
							<div key={r.t} className={`hsd-fcell hsd-fcell--${r.tone}`}>
								<div className="hsd-fcell__v">
									{r.min}
									<sup style={{ fontSize: "0.45em", fontWeight: 600 }}>min</sup>
								</div>
								<div className="hsd-fcell__l">{r.t} · {r.d}</div>
							</div>
						))}
					</div>
					<p className="hsd-lead hsd-lead--muted" style={{ marginTop: 20 }}>
						8 人开班（<span className="hsd-pow">2<sup>3</sup></span>）· 32 人满班（<span className="hsd-pow">2<sup>5</sup></span>）· 18 岁以上 · 全国 40+ 城。
					</p>
					<a href="/initiatives" className="hsd-cta--rose">报名通道 2026.10.24 起陆续开放 →</a>
					<p className="hsd-cta-note">场次将陆续上线，敬请关注</p>
				</div>
			</section>

			{/* ⭐ 参与者 FAQ */}
			<section className="hsd-section" aria-labelledby="hsd-faq-t">
				<div className="hsd-container">
					<div className="hsd-badge-row">
						<span className="hsd-badge">常见问题</span>
						<span className="hsd-badge-label">FAQ</span>
					</div>
					<h2 className="hsd-title" id="hsd-faq-t">
						第一次来，<em>你大概想问</em>
					</h2>
					<div className="hsd-faq">
						{FAQ.map((f) => (
							<details key={f.q}>
								<summary>{f.q}</summary>
								<p>{f.a}</p>
							</details>
						))}
					</div>
				</div>
			</section>

			{/* ⭐ 成为志愿者（三入口之一；志愿者体系 + 多职位，内容为草案，待共创定稿） */}
			<section className="hsd-section" id="hsd-host" aria-labelledby="hsd-host-t">
				<div className="hsd-container">
					<div className="hsd-badge-row">
						<span className="hsd-badge">成为志愿者</span>
						<span className="hsd-badge-label">Volunteer Crew</span>
					</div>
					<h2 className="hsd-title" id="hsd-host-t">
						把 Hacker Start 1024 <em>开到你的城市</em>
					</h2>
					<p className="hsd-lead">
						三个职位，总有一个适合你。
					</p>
					{/* 三职位小卡（ABC 项目线卡式：一排常驻，深读在申请页） */}
					<div className="hsd-cap3">
						{VOLUNTEER_ROLES.map((r, i) => (
							<div key={r.t} className="hsd-tile" style={r.featured ? { borderColor: "#c9497d", borderWidth: 2 } : undefined}>
								<div className="hsd-tile__t"><span className="hsd-tile__n">{i + 1}</span>
									{r.t}
									{r.featured ? (
										<span style={{ marginLeft: 8, fontSize: 12, background: "#faedf2", color: "#b0406b", borderRadius: 999, padding: "3px 10px", fontWeight: 700 }}>首批最需要</span>
									) : null}
									<small style={{ display: "block", color: "#b9b3c2", fontWeight: 400, letterSpacing: "0.08em" }}>{r.en}</small>
								</div>
								<div className="hsd-tile__d" style={{ marginBottom: 8 }}>{r.one}</div>
								<div className="hsd-tile__d" style={{ color: "#c9497d" }}>{r.fit}</div>
							</div>
						))}
					</div>
					{/* 当前批次卡（状态徽章 + 截止 + 申请入口） */}
					<div className="hsd-tile" style={{ marginTop: 14, display: "flex", flexWrap: "wrap", alignItems: "center", gap: "10px 18px" }}>
						<span style={{ background: "#2fa69d", color: "#fff", borderRadius: 8, padding: "4px 10px", fontSize: 13, fontWeight: 700 }}>进行中</span>
						<span style={{ fontWeight: 800, fontSize: 16 }}>第 1 批 · 首批志愿者招募</span>
						<span style={{ fontSize: 13.5, color: "#857f8f" }}>报名截止 2026.10.10（草案）· 执行周期 2026.10-2027</span>
						<span style={{ flex: 1 }} />
						<a href="/prototype/hackerstart-1024/host-apply" className="hsd-cta--rose" style={{ marginTop: 0 }}>申请成为志愿者 →</a>
					</div>
					{/* 支持一行 */}
					<div className="hsd-endorse" style={{ marginTop: 14 }}>
						<span>课程包与 SOP</span>
						<span>运营平台 · 不碰钱</span>
						<span>免费场地合作</span>
						<span>40+ 城社区与曝光</span>
					</div>
					<p className="hsd-cta-note">职位详情、四段流程与常见问题见申请页 · 志愿者权益共创定稿中</p>
				</div>
			</section>

			{/* ⭐ 时间线 */}
			<section className="hsd-section" aria-labelledby="hsd-tl-t">
				<div className="hsd-container">
					<div className="hsd-badge-row">
						<span className="hsd-badge">接下来会发生什么</span>
						<span className="hsd-badge-label">Timeline</span>
					</div>
					<h2 className="hsd-title" id="hsd-tl-t">
						2026.10.24 启动，<em>批次滚动至 2027</em>
					</h2>
					<div className="hsd-timeline">
						{TIMELINE.map((m) => (
							<div key={m.t} className={`hsd-tl__item${m.start ? " hsd-tl__item--start" : ""}`}>
								<div className="hsd-tl__t">{m.t}</div>
								<div className="hsd-tl__d">{m.d}</div>
							</div>
						))}
					</div>
				</div>
			</section>

			{/* 我们是谁 */}
			<section className="hsd-section" aria-labelledby="hsd-who-t">
				<div className="hsd-container">
					<div className="hsd-badge-row">
						<span className="hsd-badge">我们是谁</span>
						<span className="hsd-badge-label">Who We Are</span>
					</div>
					<h2 className="hsd-title" id="hsd-who-t">
						十年社区，<em>可以被查证的十年</em>
					</h2>
					<p className="hsd-lead">
						Coding Girls Club 程序媛汇，2016 年 6 月 1 日成立，中国首个、规模最大的女性编程社区（社会企业）。
					</p>
					<div className="hsd-stats">
						{HISTORY.map((s) => (
							<div key={s.l} className="hsd-stat">
								<div className="hsd-stat__v">{s.v}</div>
								<div className="hsd-stat__l">{s.l}</div>
							</div>
						))}
					</div>
					<p className="hsd-stats__cap">2016-2025 历史累计</p>
					{/* ⭐ 背书挂真链接（无链接的按方案保留文字） */}
					<div className="hsd-endorse">
						{ENDORSE.map((e) =>
							e.url ? (
								<a key={e.text} href={e.url} target="_blank" rel="noopener noreferrer">{e.text}</a>
							) : (
								<span key={e.text}>{e.text}</span>
							),
						)}
					</div>
					<div className="hsd-lever">本轮一个 campaign 的参与人数目标 ≈ 过去十年累计。</div>
				</div>
			</section>

			{/* 品牌专场合作 */}
			<section className="hsd-section" id="hsd-brand" aria-labelledby="hsd-brand-t">
				<div className="hsd-section__corner" aria-hidden="true" />
				<div className="hsd-container">
					<div className="hsd-badge-row">
						<span className="hsd-badge hsd-badge--mint">品牌专场合作</span>
						<span className="hsd-badge-label">Your Branded Track</span>
					</div>
					<h2 className="hsd-title" id="hsd-brand-t">
						64 场（<span className="hsd-pow">2<sup>6</sup></span>）品牌专场，<em>用为你定制的课程</em>
					</h2>
					<p className="hsd-lead">
						CGC 十年编程社区 × 你的品牌：把 512-2,048 名付费用户变成你的产品第一批普通人用户。
					</p>
					<div className="hsd-formula">
						<div className="hsd-fcell hsd-fcell--pink">
							<div className="hsd-fcell__v">16<span className="hsd-pow">2<sup>4</sup></span></div>
							<div className="hsd-fcell__l">个品牌席位</div>
						</div>
						<span className="hsd-fop" aria-hidden="true">×</span>
						<div className="hsd-fcell hsd-fcell--mint">
							<div className="hsd-fcell__v">64<span className="hsd-pow">2<sup>6</sup></span></div>
							<div className="hsd-fcell__l">场品牌专场</div>
						</div>
						<span className="hsd-fop" aria-hidden="true">＝</span>
						<div className="hsd-fcell hsd-fcell--solid">
							<div className="hsd-fcell__v">1,024<span className="hsd-pow">2<sup>10</sup></span></div>
							<div className="hsd-fcell__l">场全国计划</div>
						</div>
					</div>
					<div className="hsd-tiles">
						{PERKS.map((p, i) => (
							<div key={p.t} className="hsd-tile">
								<div className="hsd-tile__t"><span className="hsd-tile__n">{i + 1}</span>{p.t}</div>
								<div className="hsd-tile__d">{p.d}</div>
							</div>
						))}
					</div>
					{/* ⭐ 示例命名胶囊（P6） */}
					<div className="hsd-pill">
						<span>示例：「＿＿ × CGC 一日 Agent 工作坊 · 全国 64 场」</span>
					</div>

					{/* ⭐ 交付能力三列（P5） */}
					<p className="hsd-sub">我们凭什么交付 · How We Deliver</p>
					<div className="hsd-cap3">
						{CAPS.map((c, i) => (
							<div key={c.t} className="hsd-tile">
								<div className="hsd-tile__t"><span className="hsd-tile__n">{i + 1}</span>{c.t}</div>
								<div className="hsd-tile__d">{c.d}</div>
							</div>
						))}
					</div>

					{/* ⭐ 六层价值阶梯（P7，从最硬讲起） */}
					<p className="hsd-sub">你能得到什么 · Value Ladder</p>
					<div className="hsd-ladder">
						{LADDER.map((l, i) => (
							<div key={l.t} className="hsd-ladder__step">
								<span className="hsd-ladder__n">{String(i + 1).padStart(2, "0")}</span>
								<span className="hsd-ladder__t">{l.t}</span>
								<span className="hsd-ladder__d">{l.d}</span>
							</div>
						))}
					</div>
					<p className="hsd-ladder__cap">从最硬的讲起——每层一句话一个数字</p>

					{/* ⭐ 开放共创议题（P9） */}
					<p className="hsd-sub">开放议题 · Co-create</p>
					<div className="hsd-openqs">
						{OPENQS.map((o) => (
							<div key={o.t} className="hsd-openq">
								<div className="hsd-openq__t">{o.t}</div>
								<div className="hsd-openq__d">{o.d}</div>
							</div>
						))}
					</div>
					<p className="hsd-openq__cap">以上为开放性议题，欢迎带着你的想法来聊。</p>

					<div className="hsd-pill">
						<span>专场打包合作</span><span>·</span>
						<span>资源可折抵</span><span>·</span>
						<span>首期 20 场验收后续批</span>
					</div>
					<a href="mailto:partners@codingirlsclub.com" className="hsd-cta--rose">
						聊品牌专场合作 · 48 小时内回复
					</a>
					<p className="hsd-cta-note">partners@codingirlsclub.com · 品牌专场席位按签约进度更新，首批席位评审中</p>
				</div>
			</section>

			{/* ⭐ 留存位（公众号素材待提供，暂占位） */}
			<section className="hsd-section">
				<div className="hsd-container">
					<div className="hsd-follow">
						<div className="hsd-follow__row">
							<div className="hsd-follow__qr">公众号二维码<br />（素材待提供）</div>
							<div style={{ textAlign: "left" }}>
								<div className="hsd-follow__t">报名开启前，先关注我们</div>
								<div className="hsd-follow__d">首批场次 2026.10.24 上线——开放报名第一时间知道。</div>
							</div>
						</div>
						<div className="hsd-follow__tag">#hackerstart1024</div>
					</div>
				</div>
			</section>

			<footer className="hsd-footer">
				<div className="hsd-container" style={{ display: "flex", flexWrap: "wrap", justifyContent: "space-between", gap: "8px 20px" }}>
					<span>
						Coding Girls Club 程序媛汇 · 成立于 2016 · codingirlsclub.com
						<br /><a href="#hsd-host" style={{ color: "#c9497d" }}>你的城市还没有场次？来成为志愿者 →</a>
					</span>
					<b>#hackerstart1024</b>
				</div>
			</footer>
		</main>
	);
}

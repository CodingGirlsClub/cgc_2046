/**
 * 手机版原型预览页——把响应式后的宣传页与申请页装进 390px 手机壳（iframe），
 * 桌面上即可预览移动端效果；也可以直接用浏览器 DevTools 手机模式打开原路由。
 * 响应式样式在 hs1024.css 的 @media (max-width: 640px) 块。
 */
const FRAMES = [
	{ src: "/prototype/hackerstart-1024/variant-d", t: "宣传页 · 手机版", href: "http://localhost:3124/prototype/hackerstart-1024/variant-d" },
	{ src: "/prototype/hackerstart-1024/host-apply", t: "志愿者申请页 · 手机版", href: "http://localhost:3124/prototype/hackerstart-1024/host-apply" },
];

export default function MobilePreview() {
	return (
		<main style={{ background: "#e9e9ee", minHeight: "100vh", padding: "36px 20px 60px", fontFamily: "PingFang SC, sans-serif" }}>
			<h1 style={{ textAlign: "center", fontSize: 20, color: "#2b2b33", margin: "0 0 6px" }}>Hacker Start 1024 · 手机版原型预览</h1>
			<p style={{ textAlign: "center", fontSize: 13, color: "#7a7396", margin: "0 0 28px" }}>
				390 × 844（iPhone 14 Pro 尺寸）· 响应式断点 ≤640px 生效 · 小程序版见 <a href="/prototype/hackerstart-1024/weapp-d" style={{ color: "#c9497d" }}>weapp-d</a> / <a href="/prototype/hackerstart-1024/weapp-host" style={{ color: "#c9497d" }}>weapp-host</a>
			</p>
			<div style={{ display: "flex", gap: 36, justifyContent: "center", flexWrap: "wrap" }}>
				{FRAMES.map((f) => (
					<div key={f.src}>
						<p style={{ textAlign: "center", fontSize: 13, fontWeight: 700, color: "#2b2b33", margin: "0 0 10px" }}>
							{f.t}　<a href={f.href} target="_blank" rel="noreferrer" style={{ color: "#c9497d", fontWeight: 400 }}>新窗口打开 ›</a>
						</p>
						<div style={{ width: 390, height: 844, border: "10px solid #1c1c1e", borderRadius: 44, overflow: "hidden", background: "#fff", boxShadow: "0 18px 44px rgba(0,0,0,.22)" }}>
							<iframe src={f.src} title={f.t} style={{ width: "100%", height: "100%", border: 0 }} />
						</div>
					</div>
				))}
			</div>
		</main>
	);
}

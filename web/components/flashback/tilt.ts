/**
 * 名册错落（用户定稿 ②）：按 person id 的确定性旋转档位。
 *
 * hash = id 各字符 code point 之和 → %5 → fb-tilt--0..4（CSS 各档旋转角
 * -4°/-2°/+1°/+3°/+5°）。确定性：同一 id 恒同档（避免每次渲染跳动），
 * 且不依赖 Math.random——e2e 与单测可精确断言。
 */
export function tiltClass(id: string): string {
	let hash = 0;
	for (const ch of id) hash = (hash + ch.codePointAt(0)!) % 9973;
	return `fb-tilt--${hash % 5}`;
}

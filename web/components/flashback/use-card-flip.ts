"use client";

import { useCallback, useEffect, useRef, useState } from "react";

/** 半程时长：整程 0.9s（原型 E/F ia-flip-inner 的 transition 值），两段各半 */
export const FLIP_HALF_MS = 450;

export type CardFace = "front" | "back";
export type FlipPhase = "idle" | "out" | "in";

/**
 * 两段式 3D 翻面（原型 E/F「点击照片翻面写字」的 ia-flip 语言）：
 * 前半程 rotateY 0→90°（卡片转到侧棱），中点换面，后半程 -90°→0°。
 *
 * 为什么不用单容器双面（`.fb-flip-inner` + `backface-visibility`）：两面高度差极大
 * （正面卡 ~600px，背面是整张写字表单），叠面会让容器高度取两者最大值，
 * 未翻面时卡下方留一大片空白。两段式只在换面瞬间挂载目标面，高度始终由当前面决定，
 * 视觉上仍是同一张卡绕 Y 轴翻转。
 *
 * reduced-motion：跳过动画与计时，直达目标面（U4 无障碍验收）。
 */
export function useCardFlip(initial: CardFace = "front", reduced = false) {
	const [face, setFace] = useState<CardFace>(initial);
	const [phase, setPhase] = useState<FlipPhase>("idle");
	const faceRef = useRef<CardFace>(initial);
	const timers = useRef<number[]>([]);

	const clearTimers = useCallback(() => {
		timers.current.forEach((timer) => window.clearTimeout(timer));
		timers.current = [];
	}, []);

	useEffect(() => clearTimers, [clearTimers]);

	const flip = useCallback(
		(next: CardFace) => {
			if (faceRef.current === next) return;
			faceRef.current = next;
			if (reduced) {
				clearTimers();
				setPhase("idle");
				setFace(next);
				return;
			}
			clearTimers();
			setPhase("out");
			timers.current.push(
				window.setTimeout(() => {
					setFace(next);
					setPhase("in");
					timers.current.push(window.setTimeout(() => setPhase("idle"), FLIP_HALF_MS));
				}, FLIP_HALF_MS),
			);
		},
		[clearTimers, reduced],
	);

	return { face, phase, flip };
}

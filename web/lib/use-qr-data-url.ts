"use client";

/**
 * 二维码 dataURL 生成（`qrcode` 单源；收银框/核销码卡共用）。
 *
 * `source` 为 null 时不出图（返回 null）；生成失败（超长/编码异常）同样返回
 * null——调用方一律降级到可复制链接或手输码，不阻断主流程。
 */

import { useEffect, useState } from "react";
import QRCode from "qrcode";

interface Generated {
	source: string;
	width: number;
	url: string | null;
}

export function useQrDataUrl(source: string | null, width: number): string | null {
	const [generated, setGenerated] = useState<Generated | null>(null);

	useEffect(() => {
		if (source === null) return;
		let cancelled = false;
		QRCode.toDataURL(source, { width, margin: 1 })
			.then((url) => {
				if (!cancelled) setGenerated({ source, width, url });
			})
			.catch(() => {
				if (!cancelled) setGenerated({ source, width, url: null });
			});
		return () => {
			cancelled = true;
		};
	}, [source, width]);

	// 只认与当前入参匹配的产物：源切换当帧返回 null（旧图不外泄），null 源恒 null
	return generated && generated.source === source && generated.width === width
		? generated.url
		: null;
}

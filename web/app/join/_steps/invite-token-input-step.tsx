interface InviteTokenInputStepProps {
	inviteToken: string;
	setInviteToken: (value: string) => void;
	loading: boolean;
	onValidate: () => void;
	onBack: () => void;
}

export function InviteTokenInputStep({
	inviteToken,
	setInviteToken,
	loading,
	onValidate,
	onBack,
}: InviteTokenInputStepProps) {
	return (
		<>
			<h1>使用邀请链接加入</h1>
			<p>输入邀请链接中的 token 或完整链接</p>
			<div className="join-input-row">
				<input
					type="text"
					className="join-input"
					placeholder="输入邀请 token 或粘贴完整链接"
					value={inviteToken}
					onChange={(e) => {
						// 自动提取 token：如果粘贴的是完整 URL，提取 token 参数
						const val = e.target.value;
						try {
							const url = new URL(val);
							const t = url.searchParams.get("token");
							if (t) {
								setInviteToken(t);
								return;
							}
						} catch {
							// 不是 URL，直接使用输入值
						}
						setInviteToken(val);
					}}
					onKeyDown={(e) => e.key === "Enter" && onValidate()}
					disabled={loading}
					aria-label="邀请 token"
				/>
				<button
					type="button"
					className="join-button join-button--primary"
					onClick={onValidate}
					disabled={loading || !inviteToken.trim()}
				>
					{loading ? "校验中…" : "校验"}
				</button>
			</div>
			<button
				type="button"
				className="join-button join-button--ghost"
				onClick={onBack}
			>
				← 返回
			</button>
		</>
	);
}
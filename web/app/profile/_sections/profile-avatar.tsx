import { useRef } from "react";
import type { ProfileContent } from "@/lib/profile";

export function Avatar({
	content,
	editable = false,
	onFile,
}: {
	content: Pick<ProfileContent, "name" | "avatarUrl">;
	editable?: boolean;
	onFile?: (value: string) => void;
}) {
	const inputRef = useRef<HTMLInputElement>(null);
	const letter = (content.name || "?").slice(0, 1).toUpperCase();

	function handleFile(event: React.ChangeEvent<HTMLInputElement>) {
		const file = event.target.files?.[0];
		if (!file || !onFile) return;
		const reader = new FileReader();
		reader.onload = () => {
			if (typeof reader.result === "string") onFile(reader.result);
		};
		reader.readAsDataURL(file);
	}

	return (
		<div
			className={`profile-avatar-wrap ${editable ? "profile-avatar-wrap--editable" : ""}`}
		>
			{content.avatarUrl ? (
				// eslint-disable-next-line @next/next/no-img-element
				<img
					src={content.avatarUrl}
					alt={`${content.name} 的头像`}
					className="profile-avatar"
				/>
			) : (
				<span className="profile-avatar profile-avatar--fallback">
					{letter}
				</span>
			)}
			{editable && (
				<>
					<input
						ref={inputRef}
						type="file"
						accept="image/png,image/jpeg,image/webp,image/gif"
						className="profile-file-input"
						onChange={handleFile}
					/>
					<button
						type="button"
						className="profile-change-avatar"
						onClick={() => inputRef.current?.click()}
					>
						更换头像
					</button>
				</>
			)}
		</div>
	);
}
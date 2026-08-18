import { useRef } from "react";
import { useTranslations } from "next-intl";
import type { ProfileContent } from "@/lib/profile";
import {
  AVATAR_ALLOWED_TYPES,
  AVATAR_MAX_BYTES,
  AVATAR_MAX_MB,
  AVATAR_TYPE_LABEL,
  type AvatarMimeType,
} from "@/lib/profile";

/**
 * 个人资料头像（决策 B：profile 迁入 settings 后，头像仅存在于设置表单内，
 * 32px 紧凑尺寸对齐 Linear /settings/account/profile）。
 *
 * 上传校验（#018）：客户端先于后端校验 size（≤2.2MB）与 MIME 白名单，
 * 常量单源见 lib/profile.ts（与后端契约对齐，UI 文案共用）。
 */
export function Avatar({
  content,
  editable = false,
  onFile,
  onError,
}: {
  content: Pick<ProfileContent, "name" | "avatarUrl">;
  editable?: boolean;
  onFile?: (value: string) => void;
  /** 上传校验/读取失败回调（#018：表单接到 errorMsg 展示） */
  onError?: (msg: string) => void;
}) {
  const t = useTranslations("profileAvatar");
  const inputRef = useRef<HTMLInputElement>(null);
  const letter = (content.name || "?").slice(0, 1).toUpperCase();

  function handleFile(event: React.ChangeEvent<HTMLInputElement>) {
    const file = event.target.files?.[0];
    if (!file || !onFile) return;

    if (!AVATAR_ALLOWED_TYPES.includes(file.type as AvatarMimeType)) {
      onError?.(
        t("typeError", {
          types: AVATAR_ALLOWED_TYPES.map((type) => AVATAR_TYPE_LABEL[type]).join("、"),
        }),
      );
      return;
    }
    if (file.size > AVATAR_MAX_BYTES) {
      onError?.(t("sizeError", { max: AVATAR_MAX_MB }));
      return;
    }

    const reader = new FileReader();
    reader.onload = () => {
      if (typeof reader.result === "string") onFile(reader.result);
    };
    reader.onerror = () => {
      onError?.(t("readError"));
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
          alt={t("avatarAlt", { name: content.name })}
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
            {t("changeAvatar")}
          </button>
        </>
      )}
    </div>
  );
}

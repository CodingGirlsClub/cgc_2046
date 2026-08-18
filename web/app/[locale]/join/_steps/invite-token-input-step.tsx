import { useTranslations } from "next-intl";

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
  const t = useTranslations("join");
  return (
    <>
      <h1>{t("inviteTitle")}</h1>
      <p>{t("inviteHint")}</p>
      <div className="join-input-row">
        <input
          type="text"
          className="join-input"
          placeholder={t("invitePlaceholder")}
          value={inviteToken}
          onChange={(e) => {
            // 自动提取 token：如果粘贴的是完整 URL，提取 token 参数
            const val = e.target.value;
            try {
              const url = new URL(val);
              const tkn = url.searchParams.get("token");
              if (tkn) {
                setInviteToken(tkn);
                return;
              }
            } catch {
              // 不是 URL，直接使用输入值
            }
            setInviteToken(val);
          }}
          onKeyDown={(e) => e.key === "Enter" && onValidate()}
          disabled={loading}
          aria-label={t("inviteAria")}
        />
        <button
          type="button"
          className="join-button join-button--primary"
          onClick={onValidate}
          disabled={loading || !inviteToken.trim()}
        >
          {loading ? t("validating") : t("validate")}
        </button>
      </div>
      <button
        type="button"
        className="join-button join-button--ghost"
        onClick={onBack}
      >
        {t("back")}
      </button>
    </>
  );
}

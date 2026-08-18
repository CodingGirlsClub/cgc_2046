import Link from "next/link";
import { useTranslations } from "next-intl";
import { Icon } from "@/components/icons";

interface JoinErrorStepProps {
  error: string | null;
  onRetry: () => void;
}

export function JoinErrorStep({ error, onRetry }: JoinErrorStepProps) {
  const t = useTranslations("join");
  return (
    <div className="join-status-card join-status-card--error">
      <Icon name="lock" />
      <h2>{t("joinErrorTitle")}</h2>
      <p>{error}</p>
      <div className="join-actions">
        <button
          type="button"
          className="join-button join-button--outline"
          onClick={onRetry}
        >
          {t("retry")}
        </button>
        <Link href="/" className="join-button join-button--ghost">
          {t("backToHome")}
        </Link>
      </div>
    </div>
  );
}

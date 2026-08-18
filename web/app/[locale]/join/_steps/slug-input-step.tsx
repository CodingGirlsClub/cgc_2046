import { useTranslations } from "next-intl";

interface SlugInputStepProps {
  slug: string;
  setSlug: (value: string) => void;
  loading: boolean;
  onLookup: () => void;
}

export function SlugInputStep({
  slug,
  setSlug,
  loading,
  onLookup,
}: SlugInputStepProps) {
  const t = useTranslations("join");
  return (
    <>
      <h1>{t("title")}</h1>
      <p>{t("slugHint")}</p>
      <div className="join-input-row">
        <input
          type="text"
          className="join-input"
          placeholder={t("slugPlaceholder")}
          value={slug}
          onChange={(e) => setSlug(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && onLookup()}
          disabled={loading}
          aria-label={t("slugAria")}
        />
        <button
          type="button"
          className="join-button join-button--primary"
          onClick={onLookup}
          disabled={loading || !slug.trim()}
        >
          {loading ? t("querying") : t("lookup")}
        </button>
      </div>
    </>
  );
}

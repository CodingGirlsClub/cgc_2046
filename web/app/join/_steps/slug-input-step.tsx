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
  return (
    <>
      <h1>加入工作区</h1>
      <p>输入工作区标识（slug）查找并加入</p>
      <div className="join-input-row">
        <input
          type="text"
          className="join-input"
          placeholder="输入工作区 slug，如 cgc-shanghai"
          value={slug}
          onChange={(e) => setSlug(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && onLookup()}
          disabled={loading}
          aria-label="工作区 slug"
        />
        <button
          type="button"
          className="join-button join-button--primary"
          onClick={onLookup}
          disabled={loading || !slug.trim()}
        >
          {loading ? "查询中…" : "查找"}
        </button>
      </div>
    </>
  );
}

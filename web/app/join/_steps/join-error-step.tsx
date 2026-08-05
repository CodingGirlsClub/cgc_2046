import Link from "next/link";
import { Icon } from "@/components/icons";

interface JoinErrorStepProps {
  error: string | null;
  onRetry: () => void;
}

export function JoinErrorStep({ error, onRetry }: JoinErrorStepProps) {
  return (
    <div className="join-status-card join-status-card--error">
      <Icon name="lock" />
      <h2>加入失败</h2>
      <p>{error}</p>
      <div className="join-actions">
        <button
          type="button"
          className="join-button join-button--outline"
          onClick={onRetry}
        >
          重试
        </button>
        <Link href="/" className="join-button join-button--ghost">
          返回工作台
        </Link>
      </div>
    </div>
  );
}

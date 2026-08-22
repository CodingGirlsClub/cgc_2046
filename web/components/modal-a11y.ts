/**
 * 模态框 a11y 机制单源（Esc 关 + Tab focus trap + 开框聚焦）。
 *
 * payment-checkout-dialog 与 onboarding-invite-modal 共用：本 hook 只管
 * ref + keydown + 开框聚焦，JSX 壳（modal-overlay / modal-content）仍由
 * 各对话框自持。调用方把 dialogRef 挂到 role="dialog" 节点、handleKeyDown
 * 挂到 overlay 的 onKeyDown。
 */

import { useEffect, useRef } from "react";

export const FOCUSABLE_SELECTOR =
  'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

export function useDialogA11y(onClose: () => void) {
  const dialogRef = useRef<HTMLDivElement>(null);

  // 开框聚焦对话框本体（Esc/Tab trap 的焦点锚点）
  useEffect(() => {
    dialogRef.current?.focus();
  }, []);

  // Esc 关闭 + Tab focus trap（对话框内循环）
  function handleKeyDown(e: React.KeyboardEvent<HTMLDivElement>) {
    if (e.key === "Escape") {
      e.stopPropagation();
      onClose();
      return;
    }
    if (e.key !== "Tab") return;
    const el = dialogRef.current;
    if (!el) return;
    const focusables = Array.from(
      el.querySelectorAll<HTMLElement>(FOCUSABLE_SELECTOR),
    );
    if (focusables.length === 0) return;
    const first = focusables[0];
    const last = focusables[focusables.length - 1];
    const active = document.activeElement;
    if (e.shiftKey && (active === first || active === el)) {
      e.preventDefault();
      last.focus();
    } else if (!e.shiftKey && active === last) {
      e.preventDefault();
      first.focus();
    }
  }

  return { dialogRef, handleKeyDown };
}

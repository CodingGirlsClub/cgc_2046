"use client";

// #61 A-2-FE 登录/注册页（静态骨架，未接后端）
// 形态对齐 prototype-m0/app/prototype/auth/page.tsx：
//   A — 居中卡片（登录/注册 tab + 找回）
//   B — 双栏：左品牌区（多租户/形态 X 说明）+ 右表单
// 变体切换（?variant=）与主题切换（?theme=）仅为开发期工具（U3/U4 决策：
// 生产构建隐藏浮动栏；正式版主题改用户偏好设置驱动）。

import { Suspense, useState } from "react";
import { useSearchParams } from "next/navigation";
import AuthForm, { type AuthMode } from "./auth-form";
import { useAuthSubmit } from "./use-auth-submit";
import { useTheme } from "@/lib/theme-provider";

function LogoMark({ size = "h-10 w-10 text-base" }: { size?: string }) {
  return (
    <div className={`flex items-center justify-center rounded-[8px] bg-accent font-[590] text-white ${size}`}>
      C
    </div>
  );
}

/* ---------------- Variant A：居中卡片 ---------------- */
function VariantA() {
  const [mode, setMode] = useState<AuthMode>("login");
  const { onSubmit, busy, error } = useAuthSubmit();
  return (
    <div className="flex min-h-screen flex-col items-center justify-center bg-canvas px-6">
      <div className="flex items-center gap-3">
        <LogoMark />
        <div>
          <div className="l-h4 text-ink">CGC 平台</div>
          <div className="l-mono text-[11px] text-ink-3">Coding Girls Club · M0 0.2</div>
        </div>
      </div>
      <div className="mt-6 w-full max-w-sm rounded-large bg-card p-6 ring-1 ring-line">
        <AuthForm mode={mode} setMode={setMode} onSubmit={onSubmit} busy={busy} error={error} />
      </div>
      <p className="l-p mt-4 text-center text-xs text-ink-3">
        形态 X：登录后进入工作台选择；页面不执行复杂流程，操作收敛到 OpenClacky。
      </p>
    </div>
  );
}

/* ---------------- Variant B：双栏品牌 + 表单 ---------------- */
function VariantB() {
  const [mode, setMode] = useState<AuthMode>("login");
  const { onSubmit, busy, error } = useAuthSubmit();
  return (
    <div className="flex min-h-screen bg-canvas">
      <aside className="hidden w-[420px] flex-col justify-between border-r border-line bg-frame p-10 md:flex">
        <div>
          <div className="flex items-center gap-3">
            <LogoMark />
            <span className="l-h4 text-ink">CGC 平台</span>
          </div>
          <h1 className="l-h2 mt-10 text-ink">M0 地基：账号即入口</h1>
          <ul className="l-p mt-4 space-y-2 text-sm text-ink-2">
            <li>· 全局 User + ash_authentication（注册 / 登录 / token）</li>
            <li>· 一个账号可加入多个 Workspace（Membership）</li>
            <li>· 租户隔离：除 User/Workspace 外全部按租户（workspace）隔离</li>
            <li>· 形态 X：复杂流程不在页面执行，收敛到 OpenClacky</li>
          </ul>
        </div>
        <p className="l-mono text-[11px] text-ink-3">M0 0.2 · User + ash_authentication</p>
      </aside>
      <section className="flex flex-1 items-center justify-center px-6 py-10">
        <div className="w-full max-w-sm">
          <div className="md:hidden">
            <div className="flex items-center gap-3">
              <LogoMark />
              <span className="l-h4 text-ink">CGC 平台</span>
            </div>
          </div>
          <div className="l-overline mt-8 md:mt-0">欢迎回来</div>
          <h2 className="l-h2 mt-1 text-ink">{mode === "login" ? "登录 CGC" : "注册 CGC 账号"}</h2>
          <div className="mt-6">
            <AuthForm mode={mode} setMode={setMode} onSubmit={onSubmit} busy={busy} error={error} />
          </div>
        </div>
      </section>
    </div>
  );
}

/* ---------------- 开发期工具栏（U4：生产构建隐藏） ---------------- */
function DevAuthToolbar({ variant }: { variant: string }) {
  const { theme, toggleTheme } = useTheme();

  if (process.env.NODE_ENV === "production") return null;

  return (
    <div className="fixed bottom-5 left-1/2 z-50 flex -translate-x-1/2 items-center gap-1 rounded-full bg-view px-2 py-1.5 shadow-elevated ring-1 ring-line">
      <span className="ml-2 rounded-[4px] bg-accent px-2 py-0.5 font-mono text-[10px] tracking-wide text-white">
        DEV
      </span>
      <span className="min-w-[170px] text-center text-[13px] text-ink-2">
        变体 {variant} — {variant === "A" ? "居中卡片" : "双栏品牌 + 表单"}
      </span>
      <button
        onClick={toggleTheme}
        aria-label="切换主题"
        className="flex h-7 items-center justify-center rounded-[6px] px-3 text-[13px] text-ink-3 transition hover:bg-soft hover:text-ink"
      >
        {theme === "dark" ? "☾ Light" : "☀ Dark"}
      </button>
    </div>
  );
}

/* ---------------- 页面入口 ---------------- */
function LoginInner() {
  const searchParams = useSearchParams();
  const variant = searchParams.get("variant") ?? "A";

  return (
    <>
      {variant === "A" && <VariantA />}
      {variant === "B" && <VariantB />}
      <DevAuthToolbar variant={variant} />
    </>
  );
}

export default function LoginPage() {
  return (
    <Suspense fallback={<div className="p-8 text-sm text-ink-3">加载中…</div>}>
      <LoginInner />
    </Suspense>
  );
}

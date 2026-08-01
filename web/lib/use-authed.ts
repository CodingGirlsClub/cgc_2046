"use client";

import { useEffect, useState } from "react";
import { isAuthenticated } from "@/lib/auth";

export interface AuthedState {
  /** 当前登录态（confirmed=true 后为真实值；此前固定 false 用于首帧渲染） */
  authed: boolean;
  /** 是否已完成客户端 cookie 确认（挂载后微任务内读一次） */
  confirmed: boolean;
}

/**
 * 登录态确认 hook（hydration-safe，#70 QA 修复）。
 *
 * 背景：isAuthenticated() 依赖 document.cookie，SSR 时 document 不存在恒返回
 * false；若在渲染期同步读取，会导致「SSR 渲染未登录空壳 / 已登录用户客户端
 * hydration 渲染完整页」的树结构不一致 → React hydration mismatch。
 *
 * 行为：
 * - 首帧 { authed: false, confirmed: false }：SSR 与客户端 hydration 首帧一致
 *   （统一渲染未登录兜底壳），且未 confirmed 前调用方不得执行「未登录重定向」
 *   —— 否则已登录用户也会被先跳去 /login。
 * - 客户端挂载后微任务内读 cookie 确认：
 *   - 已登录 → { authed: true, confirmed: true }（触发完整页渲染，已过 hydration
 *     阶段，不会 mismatch）；
 *   - 未登录 → { authed: false, confirmed: true }（调用方据此重定向 /login）。
 */
export function useAuthed(): AuthedState {
  const [state, setState] = useState<AuthedState>({
    authed: false,
    confirmed: false,
  });

  useEffect(() => {
    // 微任务提交，规避 react-hooks/set-state-in-effect 同步 setState 警告
    queueMicrotask(() => {
      setState({ authed: isAuthenticated(), confirmed: true });
    });
  }, []);

  return state;
}

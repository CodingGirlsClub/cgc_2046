// protocol.ts — socket 请求处理（NDJSON，一行一个请求）。
// 合法请求只有两种：state（读视图）与 apply（换情境 或 回写嘴关卡结果，二选一），其余一律拒绝。

import type { Session } from "./engine";

type Response = { id: unknown; ok: true; state?: ReturnType<Session["view"]> } | { id: unknown; ok: false; error: string };

export function handleLine(session: Session, line: string): Response {
  let req: any;
  try {
    req = JSON.parse(line);
  } catch {
    return { id: null, ok: false, error: "请求不是合法 JSON" };
  }
  const id = req?.id ?? null;
  if (req?.op === "state") return { id, ok: true, state: session.view() };
  if (req?.op !== "apply") return { id, ok: false, error: `未知操作 ${String(req?.op)}` };

  const hasScene = req.scene_state !== undefined;
  const hasResult = req.stage_result !== undefined;
  if (hasScene === hasResult) return { id, ok: false, error: "apply 必须且只能带 scene_state 或 stage_result 之一" };

  if (hasScene) {
    if (typeof req.scene_state !== "string") return { id, ok: false, error: "scene_state 必须是字符串" };
    const r = session.applyScene(req.scene_state);
    return r.ok ? { id, ok: true } : { id, ok: false, error: r.error };
  }
  const { stage, met } = req.stage_result ?? {};
  if (typeof stage !== "string" || typeof met !== "boolean") {
    return { id, ok: false, error: "stage_result 必须是 {stage: string, met: boolean}" };
  }
  const r = session.applyStageResult(stage, met);
  return r.ok ? { id, ok: true } : { id, ok: false, error: r.error };
}

// acp/cards.ts — 审批与提问卡片（R19、R20）：OMP 的 session/request_permission 与 elicitation/create 挂成卡片，
// 由持有这门课的连接作答（谁算持有者由 server.ts 判定）。回合结束、停止、收尾或请求被撤回时以取消作答——从不替学员选允许。
import type {
  CreateElicitationRequest,
  CreateElicitationResponse,
  ElicitationSchema,
  RequestPermissionRequest,
  RequestPermissionResponse,
} from "@agentclientprotocol/sdk";
import { isObject } from "../security";

export type CardView =
  | {
      cardId: string;
      kind: "permission";
      toolCallId: string;
      title: string;
      toolKind: string | null;
      input?: string;
      /** 原样转交 OMP 给的选项：与学员在终端里看到的一致（R19） */
      options: { optionId: string; name: string; kind: string }[];
    }
  | { cardId: string; kind: "question"; message: string; schema: ElicitationSchema };

/** cards 只管卡片本身；turn.card / turn.card.closed 由调用方补上 courseId 发给持有者 */
export type CardEmit = (method: "turn.card" | "turn.card.closed", params: Record<string, unknown>, id?: string) => void;

type Pending = {
  view: CardView;
  /** 学员的作答 → 回给 OMP 的应答；不合法返回 null */
  accept(answer: Record<string, unknown>): object | null;
  settle(response: object, reason: "answered" | "cancelled", id?: string): void;
  cancelled: object;
};

const isAnswerValue = (v: unknown) =>
  typeof v === "string" || typeof v === "number" || typeof v === "boolean" || (Array.isArray(v) && v.every((x) => typeof x === "string"));

export type Cards = ReturnType<typeof createCards>;

export function createCards(emit: CardEmit) {
  const pending = new Map<string, Pending>();

  function open<R extends object>(view: CardView, cancelled: R, accept: Pending["accept"], signal: AbortSignal): Promise<R> {
    return new Promise((resolve) => {
      // 请求被撤回或 ACP 连接断开（OMP 退出）时，卡片以取消结束
      const abort = () => pending.get(view.cardId)?.settle(cancelled, "cancelled");
      pending.set(view.cardId, {
        view,
        accept,
        cancelled,
        settle(response, reason, id) {
          if (!pending.delete(view.cardId)) return;
          signal.removeEventListener("abort", abort);
          resolve(response as R);
          emit("turn.card.closed", { cardId: view.cardId, reason }, id);
        },
      });
      signal.addEventListener("abort", abort, { once: true });
      emit("turn.card", view);
      if (signal.aborted) abort();
    });
  }

  return {
    get size() {
      return pending.size;
    },
    /** chat.attach 时重发给新的持有者 */
    views: () => [...pending.values()].map((p) => p.view),

    permission(req: RequestPermissionRequest, signal: AbortSignal): Promise<RequestPermissionResponse> {
      const { toolCall, options } = req;
      const view: CardView = {
        cardId: crypto.randomUUID(),
        kind: "permission",
        toolCallId: toolCall.toolCallId,
        title: toolCall.title ?? "",
        toolKind: toolCall.kind ?? null,
        ...(toolCall.rawInput !== undefined && { input: JSON.stringify(toolCall.rawInput) }),
        options: options.map(({ optionId, name, kind }) => ({ optionId, name, kind })),
      };
      // 嵌套的 outcome 结构：{outcome: {outcome: "selected", optionId}}；取消是 {outcome: {outcome: "cancelled"}}
      return open(view, { outcome: { outcome: "cancelled" } }, ({ optionId }) =>
        options.some((o) => o.optionId === optionId) ? { outcome: { outcome: "selected", optionId } } : null, signal);
    },

    question(req: CreateElicitationRequest, signal: AbortSignal): Promise<CreateElicitationResponse> {
      // 只接受 form 模式：SDK 的校验器对未知 mode 有兜底分支，url 等模式能走到这里，必须在此拒绝
      if (req.mode !== "form" || !("requestedSchema" in req)) {
        console.error(`cgc-host: 拒绝非 form 模式的提问（mode=${String(req.mode).slice(0, 32)}）`);
        return Promise.resolve({ action: "decline" });
      }
      const schema = req.requestedSchema as ElicitationSchema;
      const fields = new Set(Object.keys(schema.properties ?? {}));
      const view: CardView = { cardId: crypto.randomUUID(), kind: "question", message: req.message, schema };
      return open(view, { action: "cancel" }, ({ action, content }) => {
        if (action === "decline" || action === "cancel") return { action };
        if (action !== "accept" || !isObject(content)) return null;
        const entries = Object.entries(content);
        return entries.every(([k, v]) => fields.has(k) && isAnswerValue(v)) ? { action, content } : null;
      }, signal);
    },

    /** card.answer：卡片不存在（已收起）或作答不合法都返回 false，卡片保持原样 */
    answer(params: Record<string, unknown>, id?: string): boolean {
      const p = typeof params.cardId === "string" ? pending.get(params.cardId) : undefined;
      const response = p?.accept(params);
      if (!p || !response) return false;
      p.settle(response, "answered", id);
      return true;
    },

    /** 回合结束、停止、无人在场的收尾（KTD13）：全部以取消作答 */
    cancelAll() {
      for (const p of [...pending.values()]) p.settle(p.cancelled, "cancelled");
    },
  };
}

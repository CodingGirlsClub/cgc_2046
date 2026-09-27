/**
 * cgc-play.ts — 心流学习世界的 agent 侧桥（游戏进程见 monorepo 的 omp-plugin/cgc-play/）。
 *
 * 形态：Herdr 左 pane 是 OMP（本 extension 所在），右 pane 是 cgc-play 游戏进程；
 * 两者经本地 Unix socket（~/.cgc2046/play.sock，NDJSON）交接，Herdr 只负责布局。
 *
 *   - `/cgc play`（或 `/cgc-play`）：在 Herdr 内向右 split 并启动 cgc-play；不在 Herdr 内时教用户新开标签页运行。
 *   - 游戏 → agent：mouth_stage / location_complete 事件经 sendUserMessage 交给 agent（事件驱动，不轮询游戏状态）。
 *   - agent → 游戏：game_state 读视图；game_apply 只收两种合法动作（换情境 / 回写嘴关卡结果），合法性由游戏引擎终判。
 *
 * 游戏进程不调模型、不持凭证；判定全在 agent 侧。
 * cgc-play 可执行文件从 PATH 查找；设置 CGC_PLAY_BIN 可指定路径（开发与 v1 验收期二进制未进 PATH 时用）。
 */

import { existsSync } from "fs";
import { join } from "path";

// 与 cgc-play/src/server.ts 的 defaultSocketPath 保持一致（两个包独立分发，无法共享模块）
const socketPath = () => join(process.env.HOME ?? "", ".cgc2046", "play.sock");
const REQUEST_TIMEOUT_MS = 3000;

const defaultDeps = () => ({
  env: process.env,
  which: (bin) => Bun.which(bin),
  run: (cmd) => {
    const r = Bun.spawnSync(cmd, { stdout: "pipe", stderr: "pipe" });
    return { ok: r.exitCode === 0, stdout: r.stdout.toString(), stderr: r.stderr.toString() };
  },
});

export async function launchPlay(ctx, deps = defaultDeps()) {
  const bin = deps.env.CGC_PLAY_BIN || deps.which("cgc-play");
  if (!bin) {
    ctx.ui.notify("没找到 cgc-play 程序。\n\n请先安装 cgc-play（v1 验收期由团队提供），装好后再输入 /cgc play。", "error");
    return;
  }
  if (!deps.env.HERDR_ENV || !deps.env.HERDR_PANE_ID) {
    ctx.ui.notify(`游戏需要单独一个终端窗口。\n\n请新开一个终端标签页，在里面运行：\n\n  ${bin}\n\n然后回到这里继续聊天。`, "info");
    return;
  }
  const herdr = deps.env.HERDR_BIN_PATH || "herdr";
  const split = deps.run([herdr, "pane", "split", deps.env.HERDR_PANE_ID, "--direction", "right"]);
  const paneId = split.ok ? /"pane_id":"([^"]+)"/.exec(split.stdout)?.[1] : undefined;
  if (!paneId) {
    ctx.ui.notify(`打开游戏窗格失败：${split.stderr || split.stdout || "herdr 没有返回新窗格"}`, "error");
    return;
  }
  const run = deps.run([herdr, "pane", "run", paneId, bin]);
  if (!run.ok) {
    ctx.ui.notify(`启动游戏失败：${run.stderr || run.stdout}`, "error");
    return;
  }
  ctx.ui.notify("游戏已在右侧打开。用方向键和 Enter 操作；遇到需要解释的问题，我会在这里问你。", "info");
}

function eventMessage(e) {
  if (e.ev === "mouth_stage") {
    return (
      `[游戏事件] 学员在「${e.location}」走到了需要口头回答的关卡 ${e.checklist}，游戏已暂停等你。\n\n` +
      `1. 用一句话、结合当前情境问学员：${e.prompt}\n` +
      `2. 学员回答后，逐条对照以下判据判定（只有明确满足才算满足）：\n` +
      e.judge_questions.map((q, i) => `   ${i + 1}. ${q}`).join("\n") +
      `\n3. 全部满足：调 game_apply({stage_result: {stage: "${e.checklist}", met: true}})，游戏会推进到下一关。\n` +
      `   有未满足的：只针对缺的那一点追问或给判据级反馈，不要调 game_apply；学员补充后再判。\n` +
      `不要预测通过概率，不要替学员说出答案，不要用 game_apply 跳过关卡。`
    );
  }
  if (e.ev === "location_complete") {
    return `[游戏事件] 学员完成了地点「${e.location}」的全部关卡。用一两句话具体肯定学员做对的地方（不打分、不和别人比较）。`;
  }
  return null;
}

export default function cgcPlay(pi) {
  let sock = null;
  let buf = "";
  let nextId = 1;
  const pending = new Map();

  const onData = (chunk) => {
    const lines = (buf + chunk.toString()).split("\n");
    buf = lines.pop() ?? "";
    for (const line of lines) {
      if (!line.trim()) continue;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        continue;
      }
      if (msg.ev) {
        const text = eventMessage(msg);
        if (text) pi.sendUserMessage(text, { deliverAs: "nextTurn", triggerTurn: true });
      } else if (pending.has(msg.id)) {
        pending.get(msg.id)(msg);
        pending.delete(msg.id);
      }
    }
  };

  let connecting = false;
  const tryConnect = async () => {
    if (sock || connecting || !existsSync(socketPath())) return;
    connecting = true;
    try {
      sock = await Bun.connect({
        unix: socketPath(),
        socket: {
          data: (_s, d) => onData(d),
          close: () => {
            sock = null;
            buf = "";
          },
          error: () => {
            sock = null;
          },
        },
      });
    } catch {
      sock = null; // 死 socket 或游戏正在启动：下一拍再试
    } finally {
      connecting = false;
    }
  };
  // ponytail: 每秒探一次 socket 文件（不存在时只是一次 stat），游戏随时启动都能接上；需要更省再换 fs.watch
  const timer = setInterval(tryConnect, 1000);
  timer.unref?.();
  tryConnect();

  const request = async (body) => {
    await tryConnect();
    if (!sock) return { ok: false, error: "游戏没有在运行。请先输入 /cgc play 打开游戏。" };
    const id = nextId++;
    return new Promise((resolve) => {
      const t = setTimeout(() => {
        pending.delete(id);
        resolve({ ok: false, error: "游戏没有响应（超时）" });
      }, REQUEST_TIMEOUT_MS);
      pending.set(id, (msg) => {
        clearTimeout(t);
        resolve(msg);
      });
      sock.write(JSON.stringify({ id, ...body }) + "\n");
    });
  };

  const toResult = (msg) =>
    msg.ok
      ? { content: [{ type: "text", text: JSON.stringify(msg.state ?? { ok: true }) }] }
      : { content: [{ type: "text", text: msg.error }], isError: true };

  pi.registerTool({
    name: "game_state",
    label: "game_state",
    description: "读取右侧游戏窗格的当前状态：地点、第几关、关卡目标、情境状态、是否在等学员口头回答、是否完成。",
    parameters: { type: "object", properties: {}, additionalProperties: false },
    execute: async () => toResult(await request({ op: "state" })),
  });

  pi.registerTool({
    name: "game_apply",
    label: "game_apply",
    description:
      "改变游戏世界，二选一：scene_state 切换情境（只能用地点已声明的状态）；stage_result 回写当前口头关卡的判定结果（met=true 才推进）。合法性由游戏引擎终判，非法动作会被拒绝。",
    parameters: {
      type: "object",
      properties: {
        scene_state: { type: "string", description: "要切换到的情境状态名" },
        stage_result: {
          type: "object",
          properties: { stage: { type: "string", description: "当前关卡的 checklist id" }, met: { type: "boolean" } },
          required: ["stage", "met"],
          additionalProperties: false,
        },
      },
      additionalProperties: false,
    },
    execute: async (_id, params) => toResult(await request({ op: "apply", ...params })),
  });

  pi.registerCommand("cgc-play", {
    description: "打开心流学习游戏窗格（/cgc play 的别名）",
    handler: async (_args, ctx) => launchPlay(ctx),
  });

  return {
    dispose() {
      clearInterval(timer);
      sock?.end();
      sock = null;
    },
  };
}

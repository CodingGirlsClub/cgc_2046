// ui.ts — OpenTUI 渲染：上方情境插画（Kitty Graphics，不支持时 OpenTUI 自动降级色块），下方 HUD。
// 所有规则在 engine；这里只把视图画出来、把按键翻译成 pick。

import { createCliRenderer, ImageRenderable, TextRenderable } from "@opentui/core";
import type { Session, PickResult } from "./engine";

export type SceneImages = Record<string, Uint8Array>;

export async function runUi(session: Session, images: SceneImages, onExit: () => void) {
  const r = await createCliRenderer({ exitOnCtrlC: false });
  let shownState = session.view().sceneState;
  const img = new ImageRenderable(r, {
    id: "scene",
    source: images[shownState],
    width: "100%",
    height: "60%",
    fit: "cover",
    protocol: "auto",
  });
  const hud = new TextRenderable(r, { id: "hud", content: "" });
  r.root.add(img);
  r.root.add(hud);
  await img.loadPromise;

  let cursor = 0;
  let lastStage = -1;
  let feedback = session.loc.intro ?? "";

  const render = () => {
    const v = session.view();
    if (v.sceneState !== shownState) {
      shownState = v.sceneState;
      img.source = images[shownState];
    }
    if (v.stageIndex !== lastStage) {
      lastStage = v.stageIndex;
      cursor = 0;
    }
    const lines = [`  ◎ ${session.loc.region} · ${v.title}      关卡 ${v.stageIndex + 1}/${v.stageCount}`];
    if (v.completed) {
      lines.push("", "  ✓ 这个地点完成了。", "", "  q 退出");
    } else if (v.awaitingMouth) {
      lines.push(`  当前目标：${v.stage.prompt}`, "", "  → 请在左侧聊天窗格回答 agent 的问题", "", "  q 退出");
    } else {
      lines.push(`  当前目标：${v.stage.prompt}`, "");
      if (v.progress.length) lines.push(`  已完成：${v.progress.join(" → ")}`);
      lines.push(
        "  " + v.pool.map((p, i) => `${i === cursor ? "▶" : " "}${p.picked ? "✓" : " "}${p.card}`).join("   "),
        "",
        feedback ? `  ${feedback}` : "",
        "  ←/→ 选择   Enter 确认   q 退出",
      );
    }
    hud.content = lines.join("\n");
  };

  const say = (res: PickResult) => {
    if (res.kind === "distractor") feedback = `✗ ${res.explain}（${res.anchor}）`;
    else if (res.kind === "out_of_order") feedback = "还不是这一步——先想想现在最要紧的是什么。";
    else if (res.kind === "already") feedback = "这一步已经做过了。";
    else if (res.kind === "stage_passed") feedback = "✓ 这一关过了。";
    else if (res.kind === "ok") feedback = "✓";
  };

  r.keyInput.on("keypress", (k: { name: string }) => {
    if (k.name === "q" || (k.name === "c" && (k as any).ctrl)) {
      r.destroy();
      onExit();
      return;
    }
    const v = session.view();
    if (v.awaitingMouth || v.completed || v.pool.length === 0) return;
    if (k.name === "left" || k.name === "up") cursor = (cursor - 1 + v.pool.length) % v.pool.length;
    else if (k.name === "right" || k.name === "down") cursor = (cursor + 1) % v.pool.length;
    else if (k.name === "return" || k.name === "space") say(session.pick(v.pool[cursor].card));
    else return;
    render();
  });

  render();
  return { render, destroy: () => r.destroy() };
}

---
name: cgc-quality-eval
description: CGC-2046 课程教研质量报告的判据化评审（submit_prep_quality_report 前置）。当 tutor 要求「提交质检/质量报告」「评分」「判据化评审」「按判据检查课程」，或流程到 quality_check 状态需要出 report 时使用。三层架构：确定性 grep 终判格式类判据 → judge_batch 两段式 triage 语义项 → 教材原文配对终判书外声明。产出结构化 report（score + 聚合 summary + 逐条 findings），summary 为聚合产物、禁止自由发挥。无 judge 模型时自动降级为 L1 + 嫌疑清单。
---

# CGC 质检报告判据化评审（cgc-quality-eval）

把「诚实评分」从一句纪律变成可执行的判据协议。**score 与 summary 是判据结果的聚合产物，不是生成物**——这是消灭幻觉评分报告的制度保证。

## 何时用

prep 流程进入 `quality_check`，tutor（或 agent 代 tutor）要提交 `submit_prep_quality_report` 时，**必须先走本评审**产出 report，经 tutor 确认后提交。不得跳过评审直接拍分。

## 输入

- `workspace_id` / `course_id`（取自 `list_my_workspaces` / `get_prep_status`）
- 教材原文切片（可选但强烈建议）：MinerU 产物 `full.md` 按卡锚点页切片。有它才能跑 L3 终判。

## 三层判据架构（实证定型，2026-09-22 真机验证）

每层只做自己能力边界内的事。**层不可互换**：

| 层 | 判什么 | 怎么判 | 定位 |
|---|---|---|---|
| L1 确定性 | 格式类：锚点格式（`tb:` 行内页区间必须 ASCII 连字符）、id 唯一性、rubric 非空、materials typed 形态 | grep / 正则 / 遍历 | **终判**，不烧 judge |
| L2 两段式 triage | 语义项：英文残留、无出处统计句、未定义缩写 | grep 预筛候选 → `judge_batch` 逐候选精判 | **嫌疑清单**，产出待人裁，不直接定罪 |
| L3 教材配对 | 书外声明：卡上定量断言是否存在于锚点页原文 | 教材切片为 state，逐声明 noul | **终判**（有教材原文时） |

### 三条铁律（三轮实验的失败教训，违反即退化）

1. **规则可判定的判据永远不进 judge**。锚点 en-dash 检查 grep 一次 100% 精准；同一判据交给 judge 看全文会漏报。
2. **语义项禁止全文 bool 判据**。「这卡有没有未锚定断言？」喂全卡给 judge → 43/43 全报 true，区分度为零。必须两段式：grep 抽候选（词/句），judge 只判候选，每候选带上下文。
3. **无原文的出处判据只是 triage**。「对照组约 20%」这类有研究名掩护的编造，单卡视角判不出（L2 必漏）；拿锚点页原文配对 noul 一问即死（实测 0.07）。书外声明类判据只有 L3 是终判。

## 执行流程

### 1. 拉数据

`get_course_content(workspace_id, course_id)` 取全量卡集。判据评审只对当前草稿 version 做，报告附 `draft_version`。

### 2. L1 — 确定性判据（脚本，本地跑）

对每卡检查，违规即 findings（severity=`info` 或 `minor`）：

- 锚点行（含 `tb:` 的行）页区间 `re.search(r"\d\s*[–—]\s*\d", line)` 命中即违规（en-dash/em-dash）；注意候选形态 `p142–144`（无第二 p 前缀）也算页区间。
- issue id / objective id / checklist item id 唯一性（跨卡 + 卡内）。
- rubric 数组非空且逐条 `{id, text}`；materials 全部 typed 形态（`kind` + 对应 body/url/provider 字段），无旧 `ref` 写法。
- checklist 嵌在 story 内（不是卡顶层）。

### 3. L2 — 两段式 triage（grep 候选 → judge_batch）

**预筛**（正则，注意 markdown 加粗会打断数字与「约」的相邻——模式要容错 `约\s*\**\s*[\d.]+`）：

- 英文残留候选：中文紧邻的 ≥4 字母英文词（排除既定术语/人名/地名/型号白名单后仍全量送判——白名单只用来减少候选量，不用来终判）。
- 统计证据句候选：含 `约 N%|约 N 小时/分钟/万/人/次|N%|倍于|高达|多达` 的叙述句（≤300 字符，排除 `tb:` 行、表格行、公式行）。
- 未定义缩写候选：≥2 大写字母 token，附其出现上下文。

**精判**（`judge_batch`，每候选一 state，choice 二分）：

- 英文词：`residue`（应译未译的通用词，如「successive 次潜水」） vs `legitimate`（术语保留/人名/地名/机构/型号/书名）。判据措辞强调「generic dictionary word an editor would translate」。
- 统计句：`attributed`（句内或紧邻有可识别来源：研究名/研究者/事件/机构/页码） vs `unattributed`（光秃数字）。
- 缩写：`defined`（卡内有展开或公认缩写） vs `undefined`。

**产出 = 嫌疑清单**（卡 id + 候选 + 判定 + 置信）。L2 命中不定罪——precision 实测 ~3-40%，必须标「待人工裁决」呈 tutor。对单一数字如 c19「对照组约 20%」有研究名掩护的，L2 判 `attributed` 也不要放过：直接升级进 L3。

### 4. L3 — 教材配对终判（有 full.md 时必跑）

- 按卡锚点页从教材 `full.md` 切原文段（MinerU 产物；content_list.json 的 page_idx 对齐）。
- `judge_batch`：state = 原文段；questions = 该卡每条定量声明一个 noul（instructions 写死声明内容：「Does the source state ...?」，criteria 两分支写明什么算出现）。
- `noul < 0.5` = 书外声明实锤 → findings（severity=`minor` 或 `major`，看声明性质：统计证据类 minor，安全立场类 major）。
- 书内数字（noul ≥ 0.5）放行，不作 finding。

### 5. 聚合产出 report

```
score = 100 - 5×L3实锤数 - 2×L1违规数 - 1×L2嫌疑数（权重基线 v1，tutor 可调）
summary = 「判据化评审 N 条判据：通过 X，违规 Y（L1 格式 a / L3 书外声明 b），待裁决嫌疑 Z。
           书外声明：[卡id:声明]…。格式违规：[卡id]…。」   ← 聚合句式，禁止自由发挥、
                                                            禁止引入判据结果之外的人名/数字
findings = L3 实锤 + L1 违规（severity 按层映射）+ L2 嫌疑（severity=info，message 标「待裁决」）
```

report 形状 = `submit_prep_quality_report` 契约：`{score, summary, findings: [{severity, message}]}`。**呈 tutor 过目确认后才提交**；tutor 对 L2 嫌疑逐条裁决（确认/驳回），驳回的从 findings 与 score 中扣除。

### 6. 降级路径

- 无 judge 模型（jev 与聊天回退都没有）：只跑 L1 + L2 预筛（纯 grep 嫌疑清单），score 不出、报告声明「判据评审未完成，缺语义层」，**不建议提交**。
- 有聊天模型无 jev：流程不变（judge 角色自动回退），标注「语义层走聊天模型，置信降级」。
- 无教材原文：L3 整层跳过，报告声明「书外声明层未覆盖」——L2 的 `unattributed` 嫌疑此时升权重呈报。

## 成本与规模（实测）

43 卡课程全评审 ≈ 500 个 judge 判断 ≈ 秒级（jev 3-10s/批）≈ **$0.01 以内**。对照人工六视角自审一轮的时间成本，可忽略。

## 与 playbook 的关系

判据清单的**唯一权威在网站 tutor playbook 质检章**（演进方向：playbook 携带完整判据集与权重）。本 skill 承载的是宿主侧执行法（三层架构、两段式、配对终判、聚合纪律）——playbook 说「评什么」，本 skill 说「怎么评」。playbook 判据章存在时以其为准，本 skill 的内置判据集是 playbook 缺位时的 v1 基线。

## 纪律

- summary 只允许聚合事实（过/挂/嫌疑计数 + 卡 id 清单）。任何具体人名、研究名、数字进入 summary 前必须来自某条判据的输出，禁止模型自行补充背景知识。
- L2 嫌疑永远不定罪、不单独构成扣分依据（tutor 裁决后才计）。
- L3 的 noul 阈值 0.5；0.4-0.6 灰区复判一次（改写 instructions 措辞更死），仍灰区按「待裁决」处理。
- 报告落本地 workbench 留档（`review/判据化评审-<date>.md`），提交平台的 report 与留档一致。

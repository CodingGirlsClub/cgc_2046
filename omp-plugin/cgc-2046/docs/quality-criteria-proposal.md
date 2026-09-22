# Tutor Playbook 质检章判据化提案

> 提案对象：`backend/lib/cgc_2046/mcp/playbooks.ex` tutor playbook「诚实评分」段。
> 现状：质检章只有一句纪律（「质量评分必须诚实反映内容质量，不为冲过阈值虚报高分」），零判据、零证据要求、零权重。服务端 `submit_prep_quality_report` 只做形状校验，score/summary 全靠 tutor 侧 agent 自由生成——幻觉评分报告（已发生：summary 含幻觉人名与误记文献）的制度性根因。
> 提案：把「诚实评分」扩为固定判据协议。**score 与 summary 定义为判据结果的聚合产物，不是生成物。**
> 实证：2026-09-22 三层判据架构在某已发布 43 卡课程上真机验证（详见 `quality-eval-validation-2026-09-22.md`），教材配对终判 8/8 命中、两个已知书外实锤全部捞出。

## 一、卡级判据（每卡一组）

| # | 判据 | 类型 | severity | 证据要求 |
|---|---|---|---|---|
| K1 | story 三段（as_a/given/goal）齐全且语义完整 | 结构 | major | 缺字段即违规 |
| K2 | checklist 逐条可判定（可观察动作/可算结果/可核对事实），无「理解了/掌握了」类措辞 | 结构 | major | 引用违规条目 id |
| K3 | rubric 非空且逐条可判定 | 结构 | major | 空 rubric 违规 |
| K4 | materials 全部 typed 形态（kind + 对应 body/url/provider），无旧 ref | 格式 | minor | 引用违规字段路径 |
| K5 | 教材锚点行格式统一：`tb:chN#pX-pY`，页区间 ASCII 连字符（无 en/em-dash） | 格式 | info | 引用违规锚点行 |
| K6 | 正文统计证据句（约 N% / N 小时等）伴随可识别来源（研究名/研究者/事件/机构/页码） | 语义 | minor | 引用句 + 来源缺失说明 |
| K7 | 中文卡无应译未译英文残留（通用词典词，排除术语/专名/缩写/单位） | 语义 | minor | 引用词 + 原句 |
| K8 | 卡上定量声明存在于锚点页教材原文（书外声明 = 违规） | 配对 | minor（统计类）/ major（安全立场类） | noul < 0.5 即实锤，引用声明与配对结果 |

## 二、课程级判据

| # | 判据 | 类型 | severity |
|---|---|---|---|
| C1 | prereq DAG 无环、引用全部有效（objective id 存在） | 结构 | major |
| C2 | 有章节结构时无「未分组」卡（chapter_id 全部可解析） | 结构 | minor |
| C3 | 课程级声明（卡数/周期数/目标数）与卡集实际一致，无自相矛盾 | 语义 | minor |
| C4 | 外部引用文本与源无 n-gram 重叠（版权） | 配对 | major |
| C5 | 定量声明抽样配对锚定源（≥N 条/课程，N 按卡数取 10%） | 配对 | minor |
| C6 | id 纪律：issue/objective/checklist id 与上一发布版一致（修订不改不删） | 结构 | major |

## 三、评分与 summary 规则

```
score = 100 − 5×(K8/C4 实锭数) − 3×(major 违规数) − 2×(minor 违规数) − 1×(info 违规数)
        （权重 v1 基线，可按 workspace policy 调）
summary = 固定聚合句式：「判据化评审 N 条：通过 X，违规 Y（major a / minor b / info c）。
         实锤：[卡id:声明简述]…」
```

**summary 纪律（写进 playbook，与「诚实评分」并列）**：summary 只允许出现判据输出的聚合事实与卡 id 清单；禁止引入判据结果之外的任何人名、研究名、数字——违反即报告作废重出。

## 四、宿主侧执行法（指引到 omp plugin skill）

判据「评什么」在本 playbook；「怎么评」（三层架构：确定性 grep 终判格式类 / judge 两段式 triage 语义项 / 教材原文配对终判书外声明）由宿主侧执行件承载——OMP 接入包 `cgc-quality-eval` skill 已实现（无 judge 时降级）。OpenClacky 等其他宿主的 agent 读到本判据章后，可用各自宿主能力照判。

## 五、落地改动

1. `playbooks.ex` tutor playbook 动线第 5 步「诚实评分」段替换为判据协议（上表 + 评分规则 + summary 纪律）。
2. `submit_prep_quality_report` 不改（服务端形状校验已够；判据执行在 tutor 侧）。
3. 可选后续：report 增加 `criteria_version` 字段标记判据集版本，便于审计。

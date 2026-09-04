---
name: issue-video
description: 为课程 issue 卡制作 ManimCE 配套动画（中文口播 + CGC 品牌包装，时长由口播内容决定）。当 tutor 在教材锚定教研中说「给这张卡做视频」、要为某章/某知识点制作课堂演示动画时使用。流程：口播脚本 → tutor 确认 → 逐场 TTS → 音频驱动时间轴 → 渲染 → 合成包装 → 课程内容落 video: 引用。
---

# issue-video：issue 卡配套动画

为已确认的 issue 卡制作一条单概念演示视频（tutor 现场教学投影用；时长不设硬限，由口播内容决定）。
**按需触发**：tutor 明确说「给这张卡做视频」才启动，绝不主动每卡配。

## 0. 环境自检（第一步，必做）

```bash
bash <skill目录>/check_env.sh
```

任一 ✗ 就把缺失项和修复提示如实告诉 tutor，**环境不齐不硬做**。自检全绿时会
输出两行品牌素材绝对路径：`LOGO_PATH`（方形）抄进 scene.py 常量区；
`LOGO_H_PATH`（横排）留给第 6 步角标命令。别手猜。自检还会报告 fish-audio
引擎状态（`○` 未启用不算缺失，不影响全绿）。

## 1. 工作目录约定

视频产物归**课程工作区**（agent 当前工作目录）。视频是课程的产物；教材目录只存
toc.json / full.md / images 等教材解析产物，不存视频：

```
<课程工作区>/videos/<章id>/
  narration.md     # 口播脚本（tutor 确认的那一份）
  audio/s*.mp3     # 逐场 TTS
  scene.py         # 本场视频的场景代码
  <章id>.mp4       # 最终成片
```

## 2. 流程（七步，②是人工门）

1. **选材**：从该章卡的 objectives/activity + 教材章切片里选**一个**核心概念——
   一视频一概念，贪多是新手第一大坑。
2. **口播脚本** `narration.md`：逐场列「场号 / 画面 / 口播文案」。文案面向学生、
   讲课口吻、口语化但沉稳。**连同确认清单一起给 tutor 确认后才继续**——清单固定
   三项：场数 / 预计总时长 / 品牌卡收尾句（末场口播）。时长随脚本内容不设硬限，
   tutor 嫌长就砍脚本；脚本一改，重出音频即可，渲染返工贵得多。
3. **逐场 TTS**（双引擎，**默认 Fish Audio**）：

   - **Fish Audio（默认）**：口播先写进临时文本文件（JSON 转义交给脚本，别手拼 curl）：

     ```bash
     python3 <skill目录>/scripts/fish_tts.py <口播文本文件> audio/s<N>.mp3
     ```

     声音 = `FISH_AUDIO_VOICE_ID`（tutor 在 fish.audio 克隆/收藏的声音 id），
     未设用平台默认声音；`FISH_AUDIO_MODEL` 作为 Fish Audio 请求 header，
     缺省为官方当前推荐的 `s2-pro`。
     依赖 `FISH_AUDIO_API_KEY`，第 0 步自检会报告是否启用。

   - **edge-tts（兜底，免 API key）**：key 未设或 Fish 调用失败时退回。
     edge-tts 仍调用在线服务，需要可用网络：

     ```bash
     edge-tts --voice zh-CN-YunjianNeural --rate=-5% \
       --text "<本场口播>" --write-media audio/s<N>.mp3
     ```

   公共：每场合成完立刻量时长（时间轴账本靠它）：

   ```bash
   ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 audio/s<N>.mp3
   ```

   需要对位画面时刻的场（如「代入数值」要卡在变形动画上）：把口播拆成两段，
   段内词级时间不可控。换引擎/换声音只影响本步，后续流程不变。
4. **scene.py**：抄 `<skill目录>/scene_template.py` 骨架改——结构 = **场 1 标题卡
   + N 内容场 + 末场品牌卡**，头尾两场固定必有，内容场数量随脚本；调色板、字号
   层级、PingFang SC 都别重造。标题卡与内容场**不放 logo**（露出只在末场品牌卡
   + 右下横排角标，首屏双 logo 太吵）；`LOGO_PATH` 用第 0 步自检输出填。
   `SCENE_DURATIONS` 填「第 3 步实测音频时长 + 0.5~1s 留白」，场级音画对齐靠这个
   账本，不靠手感猜。
5. **渲染**：渲染前 `export PATH="/Library/TeX/texbin:$PATH"`。
   `manim -ql` 迭代；抽帧自查（`ffmpeg -ss <t> -i … -frames:v 1`）确认中文零豆腐块、
   公式 LaTeX 排版、信息不超屏；满意后 `manim -qm` 出成片。
6. **合成包装**（ffmpeg 三步）：
   - 拼轨：`ffmpeg -i s1.mp3 -i s2.mp3 … -filter_complex "…concat=n=<段数>:v=0:a=1…"`
     ——**段数数对**；场间停顿用 anullsrc 生成静音段插入；
   - 音画合成：`-ql` 与 `-qm` 有 0.1s 级帧量化差，**音轨时长以最终 -qm 成片为准**，
     用 `apad` + `atrim` 反向对齐；
   - 角标（横排 logo，路径用自检输出的 `LOGO_H_PATH`）：
     `ffmpeg -i 合成.mp4 -i <LOGO_H_PATH> -filter_complex
     "[1:v]scale=-1:48[lg];[0:v][lg]overlay=W-w-24:H-h-24" -c:a copy 成片.mp4`
7. **落盘与报告**：先过**交付自查**再落盘——

   ```bash
   ffmpeg -y -sseof -1 -i 成片.mp4 -frames:v 1 /tmp/last.png  # 末帧：全屏品牌卡
   ffmpeg -y -ss <中点秒> -i 成片.mp4 -frames:v 1 /tmp/mid.png  # 中帧：右下角横排角标
   ```

   两帧都要亲眼看：**末帧没有全屏品牌卡（logo + 程序媛汇）= 没做完**，回第 4 步
   补末场；中帧无角标回第 6 步。自查通过后：成片归位 `videos/<章id>/`；课程内容里
   该章卡加 material `{"title": "配套动画：…", "ref": "video:<章id>"}`（随下一次
   save_course_content 整卡落盘）；向 tutor 报告路径/时长/大小。

## 3. 质量红线

- **品牌露出两处必有**：末场全屏品牌卡（方形 logo + 「程序媛汇」）+ 全程右下角
  横排角标；标题卡/内容场不放 logo；角标不能替代品牌卡，缺品牌卡 = 没做完；
- 中文一律 `Text(font="PingFang SC")`，零豆腐块；公式一律 `MathTex`（LaTeX 链）；
- 每场只证明一件事，同屏信息克制，已知量渐进揭示；
- 场级音画对位：讲什么，屏幕上正在演什么；
- tutor 没确认口播脚本之前，不进入渲染。

## 4. 坑速查（详见 scene_template.py 对应代码段注释）

含 ImageMobject 的组合用 `Group` 不用 `VGroup`（后者只收 VMobject）｜
`always_redraw` 对象用完必须 `remove()`（FadeOut 无效）｜ MathTex 多位数着色要整串
`substrings_to_isolate` ｜ Table 条目传字符串 + `element_to_mobject=Text` ｜
-ql/-qm 帧量化差 → 音轨以 -qm 为准 ｜ concat 段数数对 ｜ 对位口播拆段 ｜
品牌卡 logo 用 `SVGMobject` 吃 SVG 矢量（无分辨率账）；角标是 ffmpeg 位图，只缩不放：
源图用 SVG 导出的 4x PNG（assets 随包），模糊先查源图尺寸 ｜
fish_tts.py 只从环境变量读 key，永不打印/落盘；失败只报告 HTTP 状态或错误类型，
不会输出服务端响应正文，未完成音频不会覆盖既有文件。

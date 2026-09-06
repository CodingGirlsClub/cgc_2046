---
name: issue-video
description: tutor 明确要求为课程 issue 卡制作视频时使用。入口只负责确认授权、环境和产物位置；具体 TTS、Manim、ffmpeg 与验收步骤见 references。
---

# issue-video：issue 卡配套动画

仅在 tutor 明确提出制作视频时启动。视频产物写入课程工作区的 `media/videos/<章id>/`。

## 入口检查

1. 运行 `bash <skill目录>/check_env.sh`，缺失依赖时停止并报告。
2. 选定一个核心概念，生成口播脚本并向 tutor 确认场数、预计时长和品牌收尾句。
3. tutor 确认后，按 [视频制作流程](references/video-procedure.md) 执行 TTS、场景、渲染、包装和交付自查。

## 交付约束

- tutor 未确认脚本前不得渲染。
- 末场必须有全屏品牌卡，全片必须有右下角横排角标。
- 通过末帧和中帧检查后，使用 `save_course_content` 写入 `video:<章id>` material，并报告路径、时长和大小。

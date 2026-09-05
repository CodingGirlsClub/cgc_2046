"""issue-video 场景骨架模板（从 AvgVelocityV3 蒸馏）。

用法：抄骨架 → 改文案/公式/数据 → 按「音频驱动时间轴」重设 SCENE_DURATIONS → 出片。

渲染（必须先保证 LaTeX 在 PATH）：
    export PATH="/Library/TeX/texbin:$PATH"
    manim -ql scene_template.py IssueVideoTemplate   # 快速迭代
    manim -qm scene_template.py IssueVideoTemplate   # 最终出片

完整工作流（V3 验证过）：
    1. 写口播脚本（逐场：场号/画面/文案）
    2. 逐场 TTS（默认 Fish Audio：scripts/fish_tts.py，需 FISH_AUDIO_API_KEY；
       未设 key 或调用失败退回 edge-tts --voice zh-CN-YunjianNeural --rate=-5%，见 SKILL.md 第 3 步）
    3. ffprobe 实测每段时长，回填脚本
    4. 按 SCENE_DURATIONS 账本模式重排动画（本文件所有 wait 都是「场时长 - 已知动画时长」的算术）
    5. manim -qm 出无声视频
    6. ffmpeg 拼轨合成（见文件底部 assemble 注释块）
"""

from manim import *

# ---------------------------------------------------------------------------
# 参数区：调色板 / 字体 / 字号层级 / 品牌素材 / 时间轴
# ---------------------------------------------------------------------------

FONT = "PingFang SC"  # 中文正文一律 Text(font=FONT)，绝不用 Tex/MathTex 排中文

# 统一调色板：深蓝灰底 + 米白正文 + 三语义强调色（全片一致，别中途换色）
BG = ManimColor("#1B2432")      # 底：深蓝灰（不要纯黑虚空）
INK = ManimColor("#E8ECF1")     # 正文：米白
MUTED = ManimColor("#8A94A6")   # 弱化标注
C_S = ManimColor("#5BC0EB")     # 语义色 1（示例：路程 s）
C_T = ManimColor("#F7B267")     # 语义色 2（示例：时间 t）
C_V = ManimColor("#FF6B6B")     # 强调/结果色（速度、答案、标题短划线）

# 字号层级：标题 52 / 问题 38 / 场标题 30 / 正文 26 / 标注 22
SIZE_TITLE, SIZE_QUESTION, SIZE_HEAD, SIZE_BODY, SIZE_LABEL = 52, 38, 30, 26, 22

# 品牌素材：绝对路径用 check_env.sh 输出值填充（随安装位置变，别手猜）。
# 方形 logo（SVG 矢量，SVGMobject 渲染，任意分辨率锐利）→ 末场品牌卡；
# 横排 logo（PNG 位图）→ 包装层角标（ffmpeg 用，scene.py 不涉及）。
LOGO_PATH = "/replace-with-LOGO_PATH-from-check_env/cgc_logo_orange_white.svg"

# 音频驱动时间轴（账本模式）：
#   每场画面时长 = 该场口播音频 ffprobe 实测时长 + 0.4s 呼吸（场间停顿含在内）；
#   场切换发生在下一段口播开讲前 0.3s（画面先行，声音随后）；
#   场 4 这种「变形必须落在某句口播上」的，TTS 拆成两段（4a/4b），
#   场时长 = 4a + 0.4（段间停顿）+ 4b + 0.4。
# 下面数组是 V3 的实测示例值，实际使用时逐场替换为你的 ffprobe 实测值。
#
# 坑：-ql(15fps) 与 -qm(30fps) 帧量化不同，同一代码成片时长差 ~0.1s。
#     时长账本必须以最终 -qm 产物为准，音轨最后用 apad+atrim 反向对齐（别反过来）。
D1, D2, D3, D4, D5, D6, D7 = 5.512, 13.432, 18.472, 20.6, 15.208, 10.864, 6.916


def T(s, size=SIZE_BODY, color=INK, **kwargs):
    return Text(s, font=FONT, font_size=size, color=color, **kwargs)


class IssueVideoTemplate(Scene):
    """骨架 = 场 1 标题卡 + N 内容场 + 末场品牌卡：头尾两场固定必有，内容场数量随脚本。
    本文件给 5 个内容场示例（情境/问题/公式推导/直觉化/小结），占位内容直接可渲染。
    每场只证明一件事；品牌卡不可被包装层角标替代。"""

    def construct(self):
        self.camera.background_color = BG
        self.scene_1_title()
        self.scene_2_context()
        self.scene_3_question()
        self.scene_4_formula()
        self.scene_5_intuition()
        self.scene_6_summary()
        self.scene_7_brand()

    # ------------------------------------------------------------------
    # 场 1：标题卡（固定必有）—— 章节眉线 + 主题 + 强调短划线。
    # 不放 logo：品牌露出 = 末场品牌卡 + 右下角横排角标，首屏双 logo 太吵。
    # ------------------------------------------------------------------
    def scene_1_title(self):
        over = T("第一章 · 比较运动的快慢", SIZE_LABEL, MUTED)
        title = T("平均速度", SIZE_TITLE)
        rule = Line(LEFT * 1.2, RIGHT * 1.2, color=C_V, stroke_width=3)
        over.next_to(title, UP, buff=0.45)
        rule.next_to(title, DOWN, buff=0.35)
        g = VGroup(over, title, rule).move_to(ORIGIN)

        self.play(FadeIn(over, shift=UP * 0.3), run_time=0.7, rate_func=smooth)
        self.play(Write(title), run_time=1.2)
        self.play(Create(rule), run_time=0.6)
        self.wait(D1 - 0.7 - 1.2 - 0.6 - 0.7)  # 账本：剩余时间留白
        self.play(FadeOut(g, shift=UP * 0.5), run_time=0.7)

    # ------------------------------------------------------------------
    # 场 2：情境 —— 运动主体（ValueTracker 驱动）+ 数据渐进揭示（Table）
    # ------------------------------------------------------------------
    def scene_2_context(self):
        start_x, end_x, y = -5.0, 5.0, -0.4
        route = Line([start_x, y, 0], [end_x, y, 0], color=MUTED, stroke_width=4)
        st_a, st_b = Dot(route.get_start(), color=INK), Dot(route.get_end(), color=INK)
        lab_a = T("北京南站", SIZE_LABEL).next_to(st_a, DOWN, buff=0.3)
        lab_b = T("天津站", SIZE_LABEL).next_to(st_b, DOWN, buff=0.3)
        head = T("京津城际：北京南 → 天津", SIZE_BODY, MUTED).to_edge(UP, buff=0.8)
        train = RoundedRectangle(
            corner_radius=0.1, width=0.7, height=0.36,
            fill_color=C_V, fill_opacity=1, stroke_width=0,
        ).move_to([start_x, y + 0.28, 0])

        self.play(FadeIn(head, shift=DOWN * 0.2), run_time=0.5)
        self.play(Create(route), run_time=1.0, rate_func=smooth)
        self.play(
            LaggedStart(FadeIn(st_a), FadeIn(lab_a), FadeIn(st_b), FadeIn(lab_b), lag_ratio=0.25),
            run_time=1.2,
        )
        self.play(FadeIn(train, shift=LEFT * 0.4), run_time=0.4)

        # 数据表。坑：Table 会把每个条目再过一遍 element_to_mobject（默认 Paragraph），
        # 直接塞 Text 实例会被 Paragraph 当字符串 join → TypeError。
        # 正确姿势：传原始字符串 + element_to_mobject=Text + element_to_mobject_config。
        table = Table(
            [["物理量", "数值"], ["路程 s", "120 km"], ["时间 t", "30 min"]],
            include_outer_lines=True,
            element_to_mobject=Text,
            element_to_mobject_config={"font": FONT, "font_size": 22, "color": INK},
        ).scale(0.8).move_to([0, 1.25, 0])  # 别放太高：给场标题留出头顶空间
        # 条目建表后可再逐个着色（行优先序）：数值列贴上语义色
        entries = table.get_entries()
        entries[3].set_color(C_S)  # 120 km
        entries[5].set_color(C_T)  # 30 min

        # 场内卡点：Succession(Wait, 动画) 把数据表卡在口播念到数值的时刻出现
        x = ValueTracker(start_x)
        train.add_updater(lambda m: m.move_to([x.get_value(), y + 0.28, 0]))
        self.play(
            x.animate(run_time=6.5, rate_func=smooth).set_value(end_x),
            Succession(Wait(2.2), FadeIn(table, shift=DOWN * 0.2, run_time=0.8)),
        )
        train.clear_updaters()

        self.wait(D2 - 0.5 - 1.0 - 1.2 - 0.4 - 6.5 - 0.8)
        self.play(
            *[FadeOut(m) for m in (head, route, st_a, st_b, lab_a, lab_b, train, table)],
            run_time=0.8,
        )

    # ------------------------------------------------------------------
    # 场 3：问题 —— 状态变化演示（变速 + 仪表）→ 抛出问题文字
    # ------------------------------------------------------------------
    def scene_3_question(self):
        start_x, end_x, y = -5.0, 5.0, 0.2
        route = Line([start_x, y, 0], [end_x, y, 0], color=MUTED, stroke_width=4)
        st_a, st_b = Dot(route.get_start(), color=INK), Dot(route.get_end(), color=INK)
        lab_a = T("北京南站", SIZE_LABEL).next_to(st_a, DOWN, buff=0.25)
        lab_b = T("天津站", SIZE_LABEL).next_to(st_b, DOWN, buff=0.25)
        head = T("真实的一趟车：时快时慢", SIZE_BODY, MUTED).to_edge(UP, buff=0.8)
        train = RoundedRectangle(
            corner_radius=0.1, width=0.7, height=0.36,
            fill_color=C_V, fill_opacity=1, stroke_width=0,
        ).move_to([start_x, y + 0.28, 0])

        # 速度指示条：隐形 probe 对 ValueTracker 数值微分 + 指数平滑，always_redraw 跟随
        g_label = T("速度", SIZE_BODY, MUTED)
        g_track = RoundedRectangle(
            corner_radius=0.08, width=3.6, height=0.42,
            stroke_color=MUTED, stroke_width=1.5, fill_opacity=0,
        )
        gauge = VGroup(g_label, g_track).arrange(RIGHT, buff=0.3).move_to([0.4, -2.6, 0])
        phase = T("加速出站", SIZE_BODY, C_T).move_to([0, 1.6, 0])

        self.play(
            FadeIn(head, shift=DOWN * 0.2),
            FadeIn(VGroup(route, st_a, st_b, lab_a, lab_b, gauge)),
            FadeIn(train, shift=LEFT * 0.4),
            run_time=0.9,
        )
        self.wait(3.9)  # 等口播铺垫句说完再动车
        self.play(FadeIn(phase, shift=UP * 0.2), run_time=0.4)

        x = ValueTracker(start_x)
        spd = {"v": 0.0, "last": start_x}
        train.add_updater(lambda m: m.move_to([x.get_value(), y + 0.28, 0]))

        probe = Dot(fill_opacity=0, stroke_opacity=0)

        def measure(m, dt):
            cur = x.get_value()
            if dt > 0:
                inst = abs(cur - spd["last"]) / dt
                spd["v"] = 0.72 * spd["v"] + 0.28 * min(inst, 4.5)
            spd["last"] = cur

        probe.add_updater(measure)
        g_left = g_track.get_left() + RIGHT * 0.08
        g_fill = always_redraw(
            lambda: RoundedRectangle(
                corner_radius=0.06, width=max(spd["v"] * 0.8, 0.04), height=0.28,
                fill_color=C_V, fill_opacity=1, stroke_width=0,
            ).move_to(g_track.get_center()).align_to(g_left, LEFT)
        )
        self.add(probe, g_fill)

        # 三段变速（rush_into / linear / rush_from），与口播「加速/巡航/减速」逐句对齐
        self.play(x.animate(run_time=2.2, rate_func=rush_into).set_value(-2.6))
        phase2 = T("高速巡航", SIZE_BODY, C_T).move_to([0, 1.6, 0])
        self.play(FadeTransform(phase, phase2), run_time=0.4)
        self.play(x.animate(run_time=1.6, rate_func=linear).set_value(2.6))
        phase3 = T("减速进站", SIZE_BODY, C_T).move_to([0, 1.6, 0])
        self.play(FadeTransform(phase2, phase3), run_time=0.4)
        self.play(x.animate(run_time=3.4, rate_func=rush_from).set_value(end_x))
        self.wait(1.2)

        self.play(FadeOut(phase3), run_time=0.4)
        q = T("这一段，它到底有多快？", SIZE_QUESTION).move_to([0, 1.6, 0])
        self.play(Write(q), run_time=1.4)

        train.clear_updaters()
        # 坑：always_redraw 的对象不能 FadeOut —— 每帧重建会用 lambda 里的
        # fill_opacity=1 盖掉淡出动画。用完必须 self.remove()。
        self.remove(probe, g_fill)
        self.wait(D3 - 0.9 - 3.9 - 0.4 - 2.2 - 0.4 - 1.6 - 0.4 - 3.4 - 1.2 - 0.4 - 1.4 - 0.8)
        self.play(
            *[FadeOut(m) for m in (head, route, st_a, st_b, lab_a, lab_b, train, gauge, q)],
            run_time=0.8,
        )

    # ------------------------------------------------------------------
    # 场 4：公式推导 —— MathTex 真排版 + TransformMatchingTex 符号级变形 + 颜色编码
    # ------------------------------------------------------------------
    def scene_4_formula(self):
        cap = T("用「总路程 ÷ 总时间」把它摊平", SIZE_BODY, MUTED).to_edge(UP, buff=0.9)

        eq1 = MathTex(
            r"\bar{v}", "=", r"\frac{s}{t}",
            font_size=68, substrings_to_isolate=["s", "t"],
        )
        eq1.set_color_by_tex("s", C_S)
        eq1.set_color_by_tex("t", C_T)
        eq1.move_to([0, 0.9, 0])

        self.play(FadeIn(cap, shift=DOWN * 0.2), run_time=0.6)
        self.wait(2.8)
        self.play(Write(eq1), run_time=1.4)
        self.wait(6.4)  # 等 4a 口播收尾 + 段间停顿；「代入数值」响起时开始变形

        # 坑：MathTex 多位数/复合串着色必须整串 substrings_to_isolate，
        # 否则按单字符拆分匹配会错位（"120000" 会被拆成 1/2/0/0/0/0）。
        eq2 = MathTex(
            r"\bar{v}", "=", r"\frac{120000\ \mathrm{m}}{1800\ \mathrm{s}}",
            font_size=68, substrings_to_isolate=["120000", "1800"],
        )
        eq2.set_color_by_tex("120000", C_S)
        eq2.set_color_by_tex("1800", C_T)
        eq2.move_to(eq1)
        self.play(TransformMatchingTex(eq1, eq2), run_time=1.8)
        self.wait(4.2)  # 口播念数值期间，结果式静止可读

        eq3 = MathTex(r"\bar{v}", r"\approx", r"66.7\ \mathrm{m/s}", font_size=68)
        eq3[2].set_color(C_V)
        eq3.move_to(eq2)
        self.play(TransformMatchingTex(eq2, eq3), run_time=1.6)

        box = SurroundingRectangle(eq3, color=C_V, buff=0.28, corner_radius=0.18, stroke_width=2.5)
        self.play(Create(box), run_time=0.6)
        self.play(eq3.animate.scale(1.1), rate_func=there_and_back, run_time=0.7)
        self.wait(D4 - 0.6 - 2.8 - 1.4 - 6.4 - 1.8 - 4.2 - 1.6 - 0.6 - 0.7)
        self._formula_outro = (cap, eq3, box)

    # ------------------------------------------------------------------
    # 场 5：直觉化 —— 线性比例刻度条对比（LaggedStart 逐条长出）
    # ------------------------------------------------------------------
    def scene_5_intuition(self):
        head = T("66.7 m/s 到底有多快？", SIZE_HEAD).to_edge(UP, buff=0.9)
        base_x = -4.6
        axis = Line([base_x, -2.2, 0], [base_x, 1.7, 0], color=MUTED, stroke_width=2)
        rows = [("步行", 1.1, MUTED), ("自行车", 5.0, C_T), ("本趟列车", 66.7, C_V)]
        scale = 0.145  # 单位长度 / 数值：线性比例下悬殊对比本身就是教学点

        labels, bars, vals = VGroup(), VGroup(), VGroup()
        for i, (name, v, c) in enumerate(rows):
            yy = 1.2 - i * 1.5
            lab = T(name, SIZE_BODY).move_to([0, yy, 0]).align_to([base_x - 0.25, yy, 0], RIGHT)
            bar = Rectangle(
                width=v * scale, height=0.5,
                fill_color=c, fill_opacity=1, stroke_width=0,
            ).move_to([base_x + v * scale / 2, yy, 0])
            if v < 10:  # 短条：数值标在条右侧
                val = T(f"{v} m/s", SIZE_LABEL, c).next_to(bar, RIGHT, buff=0.2)
            else:  # 长条：数值放进条内右端，深色字
                val = T(f"{v} m/s", SIZE_BODY, BG).move_to(bar.get_right() + LEFT * 1.05)
            labels.add(lab)
            bars.add(bar)
            vals.add(val)

        cap, eq3, box = self._formula_outro
        # 场间不断戏：上一场的 FadeOut 与本场 FadeIn 并行，避免口播间隙画面全黑
        self.play(FadeOut(cap), FadeOut(eq3), FadeOut(box), FadeIn(head, shift=DOWN * 0.2), run_time=0.6)
        self.play(Create(axis), FadeIn(labels), run_time=0.8)
        self.wait(2.4)  # 等口播问句说完
        self.play(
            LaggedStart(*[GrowFromEdge(b, LEFT) for b in bars], lag_ratio=0.5),
            run_time=6.0,
        )
        self.play(LaggedStart(*[FadeIn(v) for v in vals], lag_ratio=0.3), run_time=1.0)
        self.wait(D5 - 0.6 - 0.8 - 2.4 - 6.0 - 1.0 - 0.8)
        # 淡化成背景，留给小结卡
        self.play(
            FadeOut(head),
            bars.animate.set_opacity(0.15),
            labels.animate.set_opacity(0.15),
            vals.animate.set_opacity(0.15),
            axis.animate.set_opacity(0.15),
            run_time=0.8,
        )
        self._backdrop = VGroup(bars, labels, vals, axis)

    # ------------------------------------------------------------------
    # 场 6：小结 —— 一句话结论 + 副句回扣视觉论点
    # ------------------------------------------------------------------
    def scene_6_summary(self):
        card = T("平均速度 = 总路程 ÷ 总时间", 42)
        sub = T("把一路的时快时慢，摊平成一个数", SIZE_BODY, MUTED)
        g = VGroup(card, sub).arrange(DOWN, buff=0.5).move_to(ORIGIN)
        card.move_to(g[0])
        sub.move_to(g[1])
        self.play(FadeIn(card, shift=UP * 0.3, scale=0.95), run_time=1.0)
        self.wait(4.9)  # 副句随口播后半句出现
        self.play(FadeIn(sub, shift=UP * 0.2), run_time=0.9)
        self.wait(D6 - 1.0 - 4.9 - 0.9)
        self._closing = g

    # ------------------------------------------------------------------
    # 末场：品牌卡（固定必有，角标不能替代）—— logo 锁屏 + 收尾口播 + 定格收片
    # ------------------------------------------------------------------
    def scene_7_brand(self):
        logo = SVGMobject(LOGO_PATH)  # 方形 SVG 矢量（check_env.sh 输出值填充），任意分辨率锐利
        logo.height = 2.0
        logo.move_to([0, 0.6, 0])
        brand = T("程序媛汇", SIZE_BODY, MUTED).next_to(logo, DOWN, buff=0.5)

        self.play(
            FadeOut(self._closing),
            FadeOut(self._backdrop),
            FadeIn(logo, scale=0.85),
            run_time=1.2,
            rate_func=smooth,
        )
        self.play(FadeIn(brand, shift=UP * 0.2), run_time=0.9)
        self.wait(D7 - 1.2 - 0.9)


# ---------------------------------------------------------------------------
# assemble：渲染后的音轨合成与包装（ffmpeg，V3 验证过的命令链）
#
# 1) 拼轨（0.3s 前导 + 各段 + 段间 0.4s 停顿）：
#    坑：concat 滤镜段数要数对 —— n = 音频段数×2 + 1（前导）…按实际输入数。
#    ffmpeg -y -f lavfi -t 0.3 -i "anullsrc=r=44100:cl=stereo" \
#      -i s1.mp3 -f lavfi -t 0.4 -i "anullsrc=r=44100:cl=stereo" -i s2.mp3 ... \
#      -filter_complex "[每段 aformat 归一化]...concat=n=<段数>:v=0:a=1[raw];\
#                       [raw]apad,atrim=0:<视频时长>[out]" \
#      -map "[out]" -c:a libmp3lame track.mp3
#    坑：视频时长取 -qm 产物的 ffprobe 实测值（帧量化差 ~0.1s），音轨对齐它。
#
# 2) 合成 + 右下角 64px logo 角标一次完成：
#    ffmpeg -y -i video.mp4 -i track.mp3 -i logo.png \
#      -filter_complex "[2:v]scale=64:-1[lg];[0:v][lg]overlay=W-w-24:H-h-24[v]" \
#      -map "[v]" -map 1:a -c:v libx264 -crf 18 -preset medium -pix_fmt yuv420p \
#      -c:a aac -b:a 128k final.mp4
#
# 3) 验收：ffprobe 双向核对时长（diff < 0.5s）；抽帧看画面；volumedetect 抽音
#    （口播段 mean ≈ -27dB，场间停顿段应 < -80dB）。
# ---------------------------------------------------------------------------

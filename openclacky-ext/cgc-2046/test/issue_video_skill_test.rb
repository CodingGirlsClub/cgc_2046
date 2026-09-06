# frozen_string_literal: true

require "minitest/autorun"

# issue-video skill 静态锚（教材锚定教研 · 配套动画，2026-09-02 v1.4 四次拍板）：
# - ext.yml 注册 skill 并挂载 cgc-tutor
# - SKILL.md 薄壳锚（frontmatter 注册；纪律细节已下沉 references/，不钉措辞）
# - cgc-tutor prompt 视频分支锚
# - scene_template.py / check_env.sh / logo 资产就位，模板为 ManimCE 形态
class IssueVideoSkillTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  EXT_YML = File.read(File.join(ROOT, "ext.yml"))
  SKILL = File.read(File.join(ROOT, "skills/issue-video/SKILL.md"))
  PROMPT = File.read(File.join(ROOT, "agents/cgc-tutor/system_prompt.md"))

  def test_ext_yml_registers_and_attaches_skill
    assert_includes EXT_YML, "- id: issue-video"
    assert_includes EXT_YML, "skills: [issue-video]"
  end

  def test_skill_frontmatter_and_trigger
    assert_includes SKILL, "name: issue-video"
  end

  def test_prompt_video_branch
    assert_includes PROMPT, "用户明确要求为已确认的 issue 卡制作配套视频"
    assert_includes PROMPT, "issue-video"
    assert_includes PROMPT, "不得主动为每张卡生成"
    assert_includes PROMPT, "全部以该 skill 为准"
    refute_includes PROMPT, "口播脚本（含预计总时长）"
    refute_includes PROMPT, "video:<章id>"
  end

  def test_assets_present
    assert File.exist?(File.join(ROOT, "skills/issue-video/scene_template.py"))
    assert File.exist?(File.join(ROOT, "skills/issue-video/check_env.sh"))
    assert File.exist?(File.join(ROOT, "skills/issue-video/assets/cgc_logo_orange_white.svg"))
  end

  def test_template_uses_manimce_and_palette
    t = File.read(File.join(ROOT, "skills/issue-video/scene_template.py"))
    assert_includes t, "from manim import *"
    assert_includes t, "PingFang SC"
    assert_includes t, "SCENE_DURATIONS"
    refute_includes t, "manimlib"
  end

  # 2026-09-03 反馈修订：品牌卡中文「程序媛汇」；时长不设硬限、由口播内容决定
  def test_brand_card_chinese_and_flexible_duration
    t = File.read(File.join(ROOT, "skills/issue-video/scene_template.py"))
    assert_includes t, "程序媛汇"
    refute_includes t, 'T("Coding Girls Club"'
    refute_includes SKILL, "60-90"
    refute_includes PROMPT, "60-90"
  end

  # logo 分工：方形 LOGO_PATH 进 scene.py（末场品牌卡）；横排 LOGO_H_PATH 给第 6 步
  # 角标 ffmpeg 命令；横排源图为 SVG 导出的 4x PNG；标题卡/内容场不放 logo
  def test_logo_paths_from_env_check
    env = File.read(File.join(ROOT, "skills/issue-video/check_env.sh"))
    assert_includes env, "cgc_logo_horizontal.png"
    assert_includes env, "cgc_logo_orange_white.svg"   # 方形默认指向 SVG 矢量
    t = File.read(File.join(ROOT, "skills/issue-video/scene_template.py"))
    refute_includes t, "LOGO_H_PATH"
    assert_includes t, "check_env.sh 输出"
    assert_includes t, "SVGMobject"          # 末场品牌卡：方形 SVG 矢量渲染
    refute_includes t, "ImageMobject"        # 模板内不再用位图
    assert File.exist?(File.join(ROOT, "skills/issue-video/assets/cgc_logo_horizontal.png"))
    assert File.exist?(File.join(ROOT, "skills/issue-video/assets/cgc_logo_horizontal.svg"))
  end

  # 2026-09-03 双引擎 TTS：Fish Audio 默认、edge-tts 兜底；key 只走环境变量，脚本/自检永不打印
  def test_fish_audio_engine_default_and_key_safe
    script = File.join(ROOT, "skills/issue-video/scripts/fish_tts.py")
    assert File.exist?(script)
    t = File.read(script)
    assert_includes t, "api.fish.audio/v1/tts"
    assert_includes t, "urllib"                      # stdlib 零第三方依赖
    refute_includes t, "requests"
    assert_includes t, '"model": model'
    refute_includes t, 'body["model"]'
    assert_includes t, "urllib.error.URLError"
    assert_includes t, "tempfile.NamedTemporaryFile"
    assert_includes t, "os.replace"
    assert_includes t, "os.unlink"
    refute_match(/print.*FISH_AUDIO_API_KEY/, t)     # 脚本不打印 key
    env = File.read(File.join(ROOT, "skills/issue-video/check_env.sh"))
    assert_includes env, "fish-audio（默认）"
    refute_match(/echo\s+.*\$FISH_AUDIO_API_KEY\b/, env)   # 自检不打印 key 值
  end

  def test_template_has_no_developer_machine_path
    t = File.read(File.join(ROOT, "skills/issue-video/scene_template.py"))
    refute_includes t, "/Users/"
    assert_includes t, "replace-with-LOGO_PATH-from-check_env"
  end
end

# frozen_string_literal: true

require "minitest/autorun"

# 教研配套视频物料契约锚（2026-09-06 私有化迁移）：
# 制作方法已迁入平台侧私有 tutor playbook 增量（cgc-playbooks repo 的 tutor.md，
# 构建期进入 release），公开扩展只携带执行物料。本文件钉住：
# - skill 形态已从公开扩展消失（ext.yml 无声明、skills/issue-video/ 不存在）
# - 物料就位且自洽（ManimCE 模板 / 环境自检 / TTS 脚本 / 品牌素材）
# - 物料不引用已删除的方法论文档、不含开发者机器路径、不打印 TTS key
class VideoPipelineAssetsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  VIDEO = File.join(ROOT, "agents/cgc-tutor/video")
  EXT_YML = File.read(File.join(ROOT, "ext.yml"))
  PROMPT = File.read(File.join(ROOT, "agents/cgc-tutor/system_prompt.md"))

  def test_skill_form_removed_from_public_extension
    refute_includes EXT_YML, "issue-video"
    refute Dir.exist?(File.join(ROOT, "skills/issue-video"))
  end

  def test_prompt_points_to_private_playbook_chapter
    assert_includes PROMPT, "配套视频"
    assert_includes PROMPT, "不得主动为每张卡生成"
    assert_includes PROMPT, "playbook"
    refute_includes PROMPT, "issue-video"
  end

  def test_assets_present
    assert File.exist?(File.join(VIDEO, "scene_template.py"))
    assert File.exist?(File.join(VIDEO, "check_env.sh"))
    assert File.exist?(File.join(VIDEO, "scripts/fish_tts.py"))
    assert File.exist?(File.join(VIDEO, "assets/cgc_logo_orange_white.svg"))
    assert File.exist?(File.join(VIDEO, "assets/cgc_logo_horizontal.png"))
    assert File.exist?(File.join(VIDEO, "assets/cgc_logo_horizontal.svg"))
  end

  def test_template_uses_manimce_and_palette
    t = File.read(File.join(VIDEO, "scene_template.py"))
    assert_includes t, "from manim import *"
    assert_includes t, "PingFang SC"
    # L7:SCENE_DURATIONS 必须是真常量并被代码消费,不再只是 docstring 提及
    assert_match(/^SCENE_DURATIONS\s*=\s*\[/, t)
    assert_includes t, "SCENE_DURATIONS[0]"
    refute_match(/^D1,\s*D2/, t)
    # L7:类名按课程场景泛化,全引用同步
    assert_includes t, "class CourseSceneTemplate(Scene):"
    refute_includes t, "IssueVideoTemplate"
    refute_includes t, "manimlib"
  end

  # L7:模块 docstring 只留用途一行 + 私有 playbook 指引;ffmpeg 拼轨命令链、
  # 六步方法论散文全部下线(文件底部 assemble 注释块的功能性说明不受此限)
  def test_docstring_slimmed_to_purpose_and_playbook_pointer
    t = File.read(File.join(VIDEO, "scene_template.py"))
    doc = t[/\A"""(.*?)"""/m, 1].to_s
    refute_includes doc, "ffmpeg"
    refute_includes doc, "manim -q"
    refute_includes doc, "完整工作流"
    assert_includes doc, "tutor playbook"
    assert_includes doc, "配套视频"
  end

  # 品牌卡中文「程序媛汇」（2026-09-03 反馈修订）
  def test_brand_card_chinese
    t = File.read(File.join(VIDEO, "scene_template.py"))
    assert_includes t, "程序媛汇"
    refute_includes t, 'T("Coding Girls Club"'
  end

  # logo 分工：方形 LOGO_PATH 进 scene.py（末场品牌卡，SVG 矢量渲染）；
  # 横排 LOGO_H_PATH 只出现在 check_env.sh 输出，供包装层角标命令使用
  def test_logo_paths_from_env_check
    env = File.read(File.join(VIDEO, "check_env.sh"))
    assert_includes env, "cgc_logo_horizontal.png"
    assert_includes env, "cgc_logo_orange_white.svg"
    t = File.read(File.join(VIDEO, "scene_template.py"))
    refute_includes t, "LOGO_H_PATH"
    assert_includes t, "check_env.sh 输出"
    assert_includes t, "SVGMobject"
    refute_includes t, "ImageMobject"
  end

  # 双引擎 TTS：Fish Audio 默认、edge-tts 兜底；key 只走环境变量，脚本/自检永不打印
  def test_fish_audio_script_key_safe
    t = File.read(File.join(VIDEO, "scripts/fish_tts.py"))
    assert_includes t, "api.fish.audio/v1/tts"
    assert_includes t, "urllib" # stdlib 零第三方依赖
    refute_includes t, "requests"
    assert_includes t, '"model": model'
    assert_includes t, "urllib.error.URLError"
    assert_includes t, "tempfile.NamedTemporaryFile"
    assert_includes t, "os.replace"
    refute_match(/print.*FISH_AUDIO_API_KEY/, t)
    env = File.read(File.join(VIDEO, "check_env.sh"))
    assert_includes env, "fish-audio（默认）"
    refute_match(/echo\s+.*\$FISH_AUDIO_API_KEY\b/, env)
  end

  def test_template_has_no_developer_machine_path
    t = File.read(File.join(VIDEO, "scene_template.py"))
    refute_includes t, "/Users/"
    assert_includes t, "replace-with-LOGO_PATH-from-check_env"
  end

  # 方法论唯一载体是私有 playbook 增量；物料文件不得引用已删除的 SKILL.md
  def test_assets_carry_no_methodology_references
    Dir.glob(File.join(VIDEO, "**/*.{sh,py}")).each do |f|
      refute_includes File.read(f), "SKILL.md", "#{f} 仍引用已删除的 SKILL.md"
    end
  end
end

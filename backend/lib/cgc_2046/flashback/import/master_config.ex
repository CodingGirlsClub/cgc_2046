defmodule Cgc2046.Flashback.Import.MasterConfig do
  @moduledoc """
  大表模式 preset（四张本机总表共用列形态，勿上传/勿入库）：

  - **参与状态按列判定**（`participation: :column`）——直读「参与状态」列，
    空值按 `not_selected`（不设录取名单 sheet，`Import` 侧零分叉复用
    admitted_keys 消费面）；
  - **按场次列分 archive**（`group_by: "场次key"`）——每 key 值建/复用一个
    EventArchive，name/city/occurred_on 取行内归档列（`archive_columns`），
    教练簿无行内归档列，走 `archive_overrides` 或库内已有档案兜底；
  - **列映射键 = 大表表头**——下表未列出的一切列显式跳过（无未映射列
    dry-run 报告，已裁决不加）。

  学员簿（rails-girls / girls-coding-day 学员总表）与教练簿两套 preset 独立，
  同名表头语义不同（如「编程语言/技能」仅教练簿收 `skills`，学员簿跳过）。
  """

  # 学员簿：Person 字段同源触达列（KTD3），PII 整段自动雾化（R16a）。
  @learner %{
    sheet: "学员",
    city_filter: nil,
    role: :learner,
    group_by: "场次key",
    participation: :column,
    archive_columns: %{name: "场次名", city: "城市", date: "活动日期"},
    columns: %{
      "姓名" => :full_name,
      "性别" => :gender,
      "城市" => :city,
      "职业/行业+公司" => :occupation,
      "报名时间" => :applied_at,
      "参与状态" => :participation,
      "手机号" => {:pii_answer, "phone"},
      "邮箱" => {:pii_answer, "email"},
      "微信" => {:pii_answer, "wechat"},
      "操作系统" => {:answer, "os"},
      "自我介绍" => {:answer, "self_intro"},
      "有意思的事" => {:answer, "funny_thing"},
      "好点子" => {:answer, "good_idea"},
      "参加动机" => {:answer, "motivation"},
      "社交媒体/微信" => {:answer, "social_media"},
      "GitHub" => {:answer, "github"},
      "常用称呼" => {:answer, "nickname"},
      "编程水平自评" => {:answer, "skill_self_rating"},
      "Rails/Ruby 技能自评" => {:answer, "rails_self_rating"},
      "学校/机构" => {:answer, "school"},
      "专业" => {:answer, "major"},
      "年级" => {:answer, "grade"},
      "工作年限" => {:answer, "work_years"},
      "日常工作内容" => {:answer, "work_content"},
      "所在机构及角色（原文）" => {:answer, "org_role"},
      "在校/在职状态" => {:answer, "student_status"}
    }
  }

  # 教练簿：无 城市/场次名/活动日期 行内列（archive 属性靠 override 或
  # 库内已有——教练表后跑复用学员表建的档）；职业列 = 所在公司/学校。
  @coach %{
    sheet: "教练",
    city_filter: nil,
    role: :coach,
    group_by: "场次key",
    participation: :column,
    columns: %{
      "姓名" => :full_name,
      "性别" => :gender,
      "所在公司/学校" => :occupation,
      "报名时间" => :applied_at,
      "参与状态" => :participation,
      "手机号" => {:pii_answer, "phone"},
      "邮箱" => {:pii_answer, "email"},
      "微信" => {:pii_answer, "wechat"},
      "GitHub" => {:answer, "github"},
      "希望如何介绍" => {:answer, "coach_intro_pref"},
      "教练自我介绍" => {:answer, "coach_intro"},
      "教练报名动机" => {:answer, "coach_motivation"},
      "编程语言/技能" => {:answer, "skills"},
      "可做城市（原文）" => {:answer, "coach_cities"}
    }
  }

  @doc "preset（`:learner` | `:coach`）→ 完整 config（未知 preset fail-closed raise）。"
  @spec config!(atom()) :: map()
  def config!(:learner), do: @learner
  def config!(:coach), do: @coach

  def config!(preset),
    do: raise(ArgumentError, "unknown flashback import preset: #{inspect(preset)}")
end

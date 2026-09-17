defmodule Cgc2046.Errors.InvalidAttributeValueRenderSites do
  @moduledoc """
  #680 渲染契约的 12 处自定义校验错误站点表（编译期共享模块）。

  本表历史上定义在 invalid_attribute_value_render_test.exs 内、由另一个测试文件
  （error_egress_guard_test.exs 第 8 条）跨文件**运行时**调用——全量跑时该测试
  模块不保证已加载，CI 偶发 `UndefinedFunctionError`（develop run 35216324213）。
  搬入 test/support 编译期模块后，两侧（渲染契约测试遍历断言 / 出口守卫第 8 条
  双向闸）引用同一份表，加载时机不再依赖测试执行顺序。

  站点数与站点表的对应（12 = 12）：

      schedule_validation.ex:18                → 1 行（Course；Event 由渲染契约测试专测覆盖）
      workspace_profile.ex（5 条 avatar 分支）  → 5 行
      user.ex（仅 nil 分支）                    → 1 行（空白串经 Ash :string 默认
                                                 trim?/allow_empty? 归一为 nil，
                                                 验收见渲染契约测试的空白输入专测）
      price_tier.ex（2 条）                     → 2 行
      sponsorship_tier.ex:90                   → 1 行
      venue.ex:70                              → 1 行
      companion_revision_validation.ex:36      → 1 行
  """

  @starts_at "2027-02-01T09:00:00Z"
  @ends_at "2027-02-01T08:00:00Z"
  @schedule_digest %{"starts_at" => @starts_at, "ends_at" => @ends_at}
  @schedule_message "ends_at must be after starts_at"

  # {label, build kind, 期望字段, 期望 message（逐字）, 期望 Value 摘要}。
  # 大体积分支在运行时构造，避免 3MB 字面量进 beam。
  # public 供 error_egress_guard_test 第 8 条做「AST 基线 = 行为表行数」一致性断言。
  @doc false
  def sites do
    too_large = "data:image/png;base64," <> String.duplicate("A", 3_000_000)
    too_long = "https://example.com/" <> String.duplicate("a", 2100)

    [
      {"ScheduleValidation（Course.create 时序倒置）",
       {:course_create, %{starts_at: @starts_at, ends_at: @ends_at}}, :ends_at, @schedule_message,
       @schedule_digest},
      {"avatar data URL MIME 不在白名单",
       {:profile_update, %{avatar_url: "data:text/plain;base64,AAAA"}}, :avatar_url,
       "avatar data URL MIME must be one of image/png, image/jpeg, image/webp, image/gif",
       %{"avatar_url" => "string(27)"}},
      {"avatar data URL 超体积上限", {:profile_update, %{avatar_url: too_large}}, :avatar_url,
       "avatar data URL too large (max ~2.2MB image)", %{"avatar_url" => "string(3000022)"}},
      {"avatar data URL 非 base64", {:profile_update, %{avatar_url: "data:image/png,abc"}},
       :avatar_url, "avatar data URL must be base64-encoded image",
       %{"avatar_url" => "string(18)"}},
      {"avatar http(s) URL 超长度上限", {:profile_update, %{avatar_url: too_long}}, :avatar_url,
       "avatar URL too long (max 2048 chars)", %{"avatar_url" => "string(2120)"}},
      {"avatar 既非 data URL 也非 http(s) URL", {:profile_update, %{avatar_url: "not-a-url"}},
       :avatar_url, "avatarUrl must be a data URL or http(s) URL",
       %{"avatar_url" => "string(9)"}},
      {"display_name 为 nil", {:user_update, %{display_name: nil}}, :display_name,
       "must not be blank", %{"display_name" => "nil"}},
      {"price_tiers 结构非法", {:course_create, %{price_tiers: [%{"name" => "x"}]}}, :price_tiers,
       "price tiers must be a list of maps with id/name/amount_cents keys (amount_cents integer >= 1)",
       %{"price_tiers" => "list(1)"}},
      {"pricing_enabled 开启但档位为空",
       {:course_create, %{pricing_enabled: true, price_tiers: [], starts_at: @starts_at}},
       :pricing_enabled, "pricing_enabled requires at least one price tier",
       %{"pricing_enabled" => true, "price_tiers" => "list(0)"}},
      {"sponsorship_tiers 结构非法", {:event_create, %{sponsorship_tiers: [%{"name" => "x"}]}},
       :sponsorship_tiers,
       "sponsorship tiers must be a list of maps with id (UUID)/name/benefits/exclusive keys",
       %{"sponsorship_tiers" => "list(1)"}},
      {"venue 畸形", {:event_create, %{venue: %{"city" => "杭州"}}}, :venue,
       "venue must be a map with country/province/city/district string keys",
       %{"venue" => "map"}},
      {"course_revision_id 未发布", {:event_create, %{course_revision_id: Ecto.UUID.generate()}},
       :course_revision_id, "course_revision_id must reference a published course revision",
       %{"course_revision_id" => "string(36)"}}
    ]
  end
end

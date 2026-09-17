defmodule Cgc2046.Errors.InvalidAttributeValueRenderTest do
  @moduledoc """
  #680：12 处自定义校验错误的渲染契约表（文案逐字 + `Value:` 摘要，与源码站点 1:1）。

  背景：#677 发现 Ash 的 keyword 错误转换（自定义校验返回
  `{:error, field: ..., message: ...}`）会写 `value: nil` + `has_value?: true`，
  渲染成 `Invalid value provided for x: ....\\n\\nValue: nil`；MCP 出口
  （`Cgc2046.Mcp.Errors.message/2`）把 Invalid 类逐叶 `Exception.message/1` 折叠，
  agent 由此误判「服务端把数据读成了 nil」（生产事故源）。#680 把全仓 14 处
  keyword 路径收敛为显式 `InvalidAttribute.exception(value: ...)`——DP2 删除 1 处
  不可达兜底（workspace_profile 的 `validate_avatar_url(_)`）→ 13 处；DP6 再删 1 处
  不可达空串分支（user.ex，Ash `:string` 默认把空白归一为 nil）→ 12 处。

  本表逐站点断言：

    - leaf 必须显式带 value（`has_value?` + 精确等于预期摘要，不是 nil）；
    - message 文案逐字不变（GraphQL / MCP / 前端正则的既有契约）；
    - `Exception.message(leaf)` 回显该摘要、且**不含** `Value: nil`。

  摘要口径单源 = `Cgc2046.Errors.ValueSummary.describe/1`（只回显类型/长度，
  绝不回显用户内容）；唯一例外 = `ScheduleValidation` 直接回显 ISO 起止时间
  （错误主体就是这两个值本身、~70B 有界）。

  `@expected_site_count` 是「有意识改动」闸：站点表行数变了必须同步改这个数，
  并对照 `test/cgc_2046/mcp/error_egress_guard_test.exs` 第 8 条的 AST 基线
  `@converted_keyword_error_sites`。

  站点数与站点表的对应（12 = 12）：

      schedule_validation.ex:18                → 1 行（Course；Event 由下方专测覆盖）
      workspace_profile.ex（5 条 avatar 分支）  → 5 行
      user.ex（仅 nil 分支）                    → 1 行（空白串经 Ash :string 默认
                                                 trim?/allow_empty? 归一为 nil，
                                                 验收见下方空白输入专测）
      price_tier.ex（2 条）                     → 2 行
      sponsorship_tier.ex:90                   → 1 行
      venue.ex:70                              → 1 行
      companion_revision_validation.ex:36      → 1 行
  """

  use Cgc2046.DataCase, async: true

  alias Cgc2046.Accounts.User
  alias Cgc2046.Accounts.WorkspaceProfile
  alias Cgc2046.Courses.Course
  alias Cgc2046.Events.Event

  @expected_site_count 12
  @tenant "00000000-0000-4000-8000-000000000680"
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

  defp build({:course_create, attrs}) do
    Ash.Changeset.for_create(
      Course,
      :create,
      Map.merge(%{title: "站点表", slug: "zhan-dian-biao"}, attrs),
      tenant: @tenant
    )
  end

  defp build({:event_create, attrs}) do
    Ash.Changeset.for_create(Event, :create, Map.merge(%{title: "站点表"}, attrs), tenant: @tenant)
  end

  defp build({:profile_update, attrs}) do
    Ash.Changeset.for_update(%WorkspaceProfile{}, :update_profile, attrs)
  end

  defp build({:user_update, attrs}) do
    Ash.Changeset.for_update(%User{}, :update_display_name, attrs)
  end

  defp leaf_for(changeset, field) do
    assert leaf =
             Enum.find(
               changeset.errors,
               &match?(%Ash.Error.Changes.InvalidAttribute{field: ^field}, &1)
             ),
           "缺 #{field} 的 InvalidAttribute 叶子：#{inspect(changeset.errors)}"

    leaf
  end

  test "12 个站点：文案逐字不变、leaf 显式带 Value 摘要、渲染不含 Value: nil" do
    for {label, kind, field, expected_message, expected} <- sites() do
      leaf = kind |> build() |> leaf_for(field)

      assert leaf.has_value?, "#{label}: 未显式带 value（Ash keyword 转换的体征）"
      assert leaf.value == expected, "#{label}: Value 摘要不符，实际 #{inspect(leaf.value)}"

      rendered = Exception.message(leaf)
      assert rendered =~ "Value: " <> inspect(expected), "#{label}: 渲染未回显摘要"
      assert rendered =~ expected_message, "#{label}: message 文案被改动（调用方/前端契约）"
      refute rendered =~ "Value: nil", "#{label}: 又出现误导性的 Value: nil"
    end
  end

  test "站点表与 #680 收敛基线一致（改这个数 = 有意识改动）" do
    assert length(sites()) == @expected_site_count
  end

  # DP6 验收：空白 display_name 仍被拒且文案/摘要不变——Ash `:string` 默认
  # `trim?: true, allow_empty?: false` 把它归一为 nil，落同一（唯一）错误站点。
  test "display_name 全空白/制表符仍被拒（Ash :string 归一为 nil，走同一站点）" do
    for blank <- ["   ", "\t", ""] do
      leaf = {:user_update, %{display_name: blank}} |> build() |> leaf_for(:display_name)

      assert leaf.value == %{"display_name" => "nil"}
      assert Exception.message(leaf) =~ "must not be blank"
      refute Exception.message(leaf) =~ "Value: nil"
    end
  end

  test "update_display_name 仍保留 Ash 默认 trim（DP6 删除自写 trim change 后行为不变）" do
    changeset = build({:user_update, %{display_name: "  站点表  "}})

    assert changeset.valid?
    assert Ash.Changeset.get_attribute(changeset, :display_name) == "站点表"
  end

  test "Event 与 Course 同挂 ScheduleValidation：Event 侧同样回显 ISO 起止时间" do
    leaf =
      {:event_create, %{starts_at: @starts_at, ends_at: @ends_at}}
      |> build()
      |> leaf_for(:ends_at)

    assert leaf.value == @schedule_digest
    assert Exception.message(leaf) =~ @schedule_message
    refute Exception.message(leaf) =~ "Value: nil"
  end

  test "经 MCP 出口折叠后同样回显摘要且不含 Value: nil（create_course 同形）" do
    message =
      {:course_create, %{starts_at: @starts_at, ends_at: @ends_at}}
      |> build()
      |> Map.fetch!(:errors)
      |> Ash.Error.to_error_class()
      |> Cgc2046.Mcp.Errors.message("failed to create course")

    assert message =~ @schedule_message
    assert message =~ ~s{"starts_at" => "#{@starts_at}"}
    assert message =~ ~s{"ends_at" => "#{@ends_at}"}
    refute message =~ "Value: nil"
  end
end

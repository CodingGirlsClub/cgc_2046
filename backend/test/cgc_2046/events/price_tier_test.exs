defmodule Cgc2046.Events.PriceTierTest do
  @moduledoc """
  U2：PriceTier 嵌入式定价配置（R1/R2/R4）。

  - 纯函数族：valid?/find/available?（available_until 三态）。
  - PriceTiersValidation：结构校验 + 「pricing_enabled 且无档位」拒绝（SponsorshipTiersValidation 同款挂法）。
  - R4 回归：免费活动（默认 pricing_enabled=false）字段默认值 + 空档位通过校验。
  """

  use Cgc2046.DataCase, async: false

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Events.{Course, Event, PriceTier}
  alias Cgc2046.EventsFixtures, as: EventFixtures

  describe "PriceTier.valid?（R1：档位形状）" do
    test "合法档位列表通过" do
      assert PriceTier.valid?([tier(amount_cents: 1)])
      assert PriceTier.valid?([tier(), tier(id: "t2", amount_cents: 19_900)])
      assert PriceTier.valid?([])
    end

    test "0 元 / 负数 / 非整数金额被拒（无 0 元档，session-settled）" do
      refute PriceTier.valid?([tier(amount_cents: 0)])
      refute PriceTier.valid?([tier(amount_cents: -1)])
      refute PriceTier.valid?([tier(amount_cents: "100")])
      refute PriceTier.valid?([tier(amount_cents: 1.5)])
    end

    test "缺 name / 空 id / 未知键被拒" do
      refute PriceTier.valid?([tier() |> Map.drop(["name"])])
      refute PriceTier.valid?([tier(id: "")])
      refute PriceTier.valid?([tier() |> Map.put("benefits", [])])
    end

    test "非列表 / 非 map 元素被拒" do
      refute PriceTier.valid?("not-a-list")
      refute PriceTier.valid?(["not-a-map"])
      refute PriceTier.valid?(nil)
    end
  end

  describe "PriceTier.find" do
    test "按 id 命中；不存在/nil 返回 error" do
      tiers = [tier(id: "early"), tier(id: "standard")]

      assert {:ok, found} = PriceTier.find(tiers, "early")
      assert found["id"] == "early"
      assert {:error, :tier_not_found} = PriceTier.find(tiers, "missing")
      assert {:error, :tier_not_found} = PriceTier.find(tiers, nil)
    end
  end

  describe "PriceTier.available?（R2：available_until 三态）" do
    test "nil = 长期可售" do
      assert PriceTier.available?(tier(), DateTime.utc_now())
    end

    test "未来时间可售；过去时间已停售" do
      future = DateTime.add(DateTime.utc_now(), 1, :day)
      past = DateTime.add(DateTime.utc_now(), -1, :day)

      assert PriceTier.available?(tier(available_until: future), DateTime.utc_now())
      refute PriceTier.available?(tier(available_until: past), DateTime.utc_now())
    end

    test "available_tiers 过滤过期档位（报名面数据源）" do
      past = DateTime.add(DateTime.utc_now(), -1, :day)
      future = DateTime.add(DateTime.utc_now(), 1, :day)

      tiers = [
        tier(id: "gone", available_until: past),
        tier(id: "live-until", available_until: future),
        tier(id: "forever")
      ]

      assert [%{"id" => "live-until"}, %{"id" => "forever"}] = PriceTier.available_tiers(tiers)
    end
  end

  describe "Event/Course 字段与校验（R1/R4）" do
    setup do
      admin = Fixtures.platform_admin()
      workspace = Fixtures.create_workspace(admin)
      %{admin: admin, workspace: workspace}
    end

    test "默认免费：pricing_enabled=false + 空档位，与改动前一致（R4）", ctx do
      event = EventFixtures.create_event(ctx.workspace, ctx.admin)

      assert event.pricing_enabled == false
      assert event.price_tiers == []
      assert Enum.empty?(Ash.load!(event, :available_price_tiers).available_price_tiers)

      course = EventFixtures.create_course(ctx.workspace, ctx.admin)
      assert course.pricing_enabled == false
      assert course.price_tiers == []
    end

    test "收费开启 + 合法档位通过；availablePriceTiers 暴露过滤结果", ctx do
      past = DateTime.add(DateTime.utc_now(), -1, :day)

      assert {:ok, event} =
               create_event(ctx, %{
                 pricing_enabled: true,
                 price_tiers: [tier(id: "expired", available_until: past), tier(id: "live")]
               })

      assert event.pricing_enabled == true
      loaded = Ash.load!(event, :available_price_tiers)
      assert [%{"id" => "live"}] = loaded.available_price_tiers
    end

    test "pricing_enabled=true 且空档位被拒（收费活动必须有可售档位）", ctx do
      assert {:error, error} = create_event(ctx, %{pricing_enabled: true, price_tiers: []})
      assert Exception.message(error) =~ "pricing"

      assert {:error, _} = create_course(ctx, %{pricing_enabled: true, price_tiers: []})
    end

    test "非法档位结构在入库前被拒（Event 与 Course 同一 Validation）", ctx do
      assert {:error, _} =
               create_event(ctx, %{pricing_enabled: true, price_tiers: [tier(amount_cents: 0)]})

      assert {:error, _} =
               create_event(ctx, %{
                 pricing_enabled: true,
                 price_tiers: [tier() |> Map.drop(["name"])]
               })

      assert {:error, _} =
               create_course(ctx, %{pricing_enabled: true, price_tiers: [tier(amount_cents: -5)]})
    end

    test "update 路径同样校验：免费活动保留空档位可更新标题（R4），开启收费需档位", ctx do
      event = EventFixtures.create_event(ctx.workspace, ctx.admin)

      assert {:ok, _} =
               event
               |> Ash.Changeset.for_update(:update, %{title: "新标题"})
               |> Ash.update(tenant: ctx.workspace.id, actor: ctx.admin)

      assert {:error, _} =
               event
               |> Ash.Changeset.for_update(:update, %{pricing_enabled: true})
               |> Ash.update(tenant: ctx.workspace.id, actor: ctx.admin)

      assert {:ok, updated} =
               event
               |> Ash.Changeset.for_update(:update, %{
                 pricing_enabled: true,
                 price_tiers: [tier()]
               })
               |> Ash.update(tenant: ctx.workspace.id, actor: ctx.admin)

      assert updated.pricing_enabled == true
    end
  end

  # ── 布置 ──

  defp tier(attrs \\ []) do
    base = %{
      "id" => Ecto.UUID.generate(),
      "name" => "标准票",
      "amount_cents" => 100
    }

    attrs
    |> Map.new()
    |> Enum.reduce(base, fn
      {:available_until, %DateTime{} = dt}, acc ->
        Map.put(acc, "available_until", DateTime.to_iso8601(dt))

      {k, v}, acc ->
        Map.put(acc, Atom.to_string(k), v)
    end)
  end

  defp create_event(ctx, attrs) do
    Event
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :title, "收费活动"), tenant: ctx.workspace.id)
    |> Ash.create(actor: ctx.admin)
  end

  defp create_course(ctx, attrs) do
    Course
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :title, "收费课程"), tenant: ctx.workspace.id)
    |> Ash.create(actor: ctx.admin)
  end
end

defmodule Cgc2046.Initiatives.DetachProvenanceTest do
  @moduledoc """
  issue #624「解除挂载后的语义未定义」（方案 C：保留但不锁 + 来源标记）。

  契约：

  1. detach（`initiative_id` 非空 → nil）不回收平台锁死规则强制写入的值——
     值留在 Event 上、回归普通可编辑字段；同时写入来源标记
     `detached_rule_provenance`，**只含此刻仍 locked 的规则对应的 event 字段**
     （值取 Event 当前保留值，source = "locked"）；
  2. 场主显式改写标记内字段 → 该键逐字段清除；键空 → 整列 nil；
     写同值不算「场主的决定」（不清除）；
  3. 改写未标记字段 → 标记原样；
  4. 重挂载（nil → 非空）→ 标记清空 + 新规则按 `merge_event_value/4` 生效
     （旧强制值被覆盖）；
  5. 无 locked 规则的 Initiative：detach 后标记 nil（默认项快照值仍保留）。

  标记是**持久化列**：断言一律以重读记录为准（页面重载语义），不只是写响应。
  """

  use Cgc2046.DataCase, async: true

  require Ash.Query

  alias Cgc2046.AccountsFixtures, as: F
  alias Cgc2046.Events.Event
  alias Cgc2046.EventsFixtures, as: EF
  alias Cgc2046.Initiatives.{Initiative, InitiativeRule}

  setup do
    admin = F.platform_admin("detach-provenance")
    %{admin: admin, workspace: F.create_workspace(admin)}
  end

  # 四规则齐备的 open Initiative；locked_keys 决定哪些规则锁死，
  # overrides 覆盖规则值（默认值：age 18 / 人数 8 / 截止 72h / 押金关闭）。
  defp initiative(admin, slug, locked_keys, overrides \\ %{}) do
    initiative =
      Initiative
      |> Ash.Changeset.for_create(:create, %{
        name: "Detach #{slug}",
        slug: slug,
        created_by: admin.id
      })
      |> Ash.create!(actor: admin)

    base = %{
      deposit: %{enabled: false},
      age_gate: %{min_age: 18},
      min_participants: %{count: 8},
      deadline_rule: %{hours_before_start: 72}
    }

    for {key, value} <- Map.merge(base, overrides) do
      InitiativeRule
      |> Ash.Changeset.for_create(:create, %{
        initiative_id: initiative.id,
        key: key,
        value: value,
        locked: key in locked_keys
      })
      |> Ash.create!(actor: admin)
    end

    initiative
    |> Ash.Changeset.for_update(:open, %{})
    |> Ash.update!(actor: admin)
  end

  defp draft_event(workspace, admin, attrs \\ %{}) do
    defaults = %{
      title: "解除挂载草稿",
      enrollment_policy: :open,
      starts_at: EF.days_from_now(10),
      ends_at: EF.days_from_now(11)
    }

    Event
    |> Ash.Changeset.for_create(:create, Map.merge(defaults, attrs), tenant: workspace.id)
    |> Ash.create!(tenant: workspace.id, actor: admin)
  end

  defp update_event(event, attrs, workspace, admin) do
    event
    |> Ash.Changeset.for_update(:update, attrs, tenant: workspace.id)
    |> Ash.update!(actor: admin, tenant: workspace.id)
  end

  defp mount(event, initiative, workspace, admin),
    do: update_event(event, %{initiative_id: initiative.id}, workspace, admin)

  defp detach(event, workspace, admin),
    do: update_event(event, %{initiative_id: nil}, workspace, admin)

  defp reload(event), do: Ash.get!(Event, event.id, authorize?: false)

  defp fields(marker), do: marker["fields"]

  # ── 验收 1：detach 保留值 + 标记含且仅含 locked 字段 ─────────────────────

  test "挂载 → detach：字段值不变、标记含且仅含 locked 规则字段（含 initiative 身份与 value/source）",
       ctx do
    initiative =
      initiative(ctx.admin, "detach-two-locked", [:age_gate, :min_participants])

    mounted =
      draft_event(ctx.workspace, ctx.admin)
      |> mount(initiative, ctx.workspace, ctx.admin)

    assert mounted.min_age == 18
    assert mounted.min_participants == 8
    assert mounted.detached_rule_provenance == nil

    detached = detach(mounted, ctx.workspace, ctx.admin)

    assert detached.initiative_id == nil
    # 方案 C：值留在 Event 上（不因解除挂载被清空）
    assert detached.min_age == 18
    assert detached.min_participants == 8
    assert detached.registration_deadline == mounted.registration_deadline
    assert detached.deposit_enabled == false

    assert detached.detached_rule_provenance == %{
             "initiative" => %{
               "id" => initiative.id,
               "name" => initiative.name,
               "slug" => initiative.slug
             },
             "fields" => %{
               "min_age" => %{"value" => 18, "source" => "locked"},
               "min_participants" => %{"value" => 8, "source" => "locked"}
             }
           }

    # 未锁默认项（deadline_rule / deposit）不进标记——那是挂载瞬间快照，
    # 之后场主可能已自改，标它 = 噪音（裁决 ③ 同源）
    refute Map.has_key?(fields(detached.detached_rule_provenance), "registration_deadline")
    refute Map.has_key?(fields(detached.detached_rule_provenance), "deposit_enabled")

    # 持久化（页面重载后的读面真值 = 落库值）
    assert reload(detached).detached_rule_provenance == detached.detached_rule_provenance
  end

  test "locked deposit 规则标记它强制写入的两个字段（开关 + 金额）", ctx do
    initiative =
      initiative(ctx.admin, "detach-deposit", [:deposit, :deadline_rule], %{
        deposit: %{enabled: true, amount_cents: 6900}
      })

    detached =
      draft_event(ctx.workspace, ctx.admin)
      |> mount(initiative, ctx.workspace, ctx.admin)
      |> detach(ctx.workspace, ctx.admin)

    assert detached.deposit_enabled == true
    assert detached.deposit_amount_cents == 6900

    assert fields(detached.detached_rule_provenance) == %{
             "deposit_amount_cents" => %{"value" => 6900, "source" => "locked"},
             "deposit_enabled" => %{"value" => true, "source" => "locked"},
             # jsonb 里 DateTime 以 ISO8601 字符串落库（读面即此形状）
             "registration_deadline" => %{
               "value" =>
                 DateTime.to_iso8601(DateTime.truncate(detached.registration_deadline, :second)),
               "source" => "locked"
             }
           }
  end

  # ── 验收 2：逐字段清除 ────────────────────────────────────────────────────

  test "编辑标记内字段：该键消失、其余键保留；编辑到最后一个 → 整列 nil", ctx do
    initiative =
      initiative(ctx.admin, "detach-clear", [:age_gate, :min_participants])

    detached =
      draft_event(ctx.workspace, ctx.admin)
      |> mount(initiative, ctx.workspace, ctx.admin)
      |> detach(ctx.workspace, ctx.admin)

    assert map_size(fields(detached.detached_rule_provenance)) == 2

    edited = update_event(detached, %{min_age: 30}, ctx.workspace, ctx.admin)
    assert edited.min_age == 30

    assert fields(edited.detached_rule_provenance) == %{
             "min_participants" => %{"value" => 8, "source" => "locked"}
           }

    assert reload(edited).detached_rule_provenance == edited.detached_rule_provenance

    last = update_event(edited, %{min_participants: 12}, ctx.workspace, ctx.admin)
    assert last.min_participants == 12
    assert last.detached_rule_provenance == nil
    assert reload(last).detached_rule_provenance == nil
  end

  test "写同值不算「场主的决定」：标记原样保留", ctx do
    initiative = initiative(ctx.admin, "detach-same-value", [:age_gate])

    detached =
      draft_event(ctx.workspace, ctx.admin)
      |> mount(initiative, ctx.workspace, ctx.admin)
      |> detach(ctx.workspace, ctx.admin)

    # web 表单每次保存都会原样回传 minAge/minParticipants——同值回传不得清标记
    resaved =
      update_event(
        detached,
        %{min_age: 18, min_participants: nil, title: "同值回传"},
        ctx.workspace,
        ctx.admin
      )

    assert resaved.detached_rule_provenance == detached.detached_rule_provenance
  end

  test "detach 同一次写入里改标记字段：该字段不进标记（编辑优先）", ctx do
    initiative =
      initiative(ctx.admin, "detach-with-edit", [:age_gate, :min_participants])

    detached =
      draft_event(ctx.workspace, ctx.admin)
      |> mount(initiative, ctx.workspace, ctx.admin)
      |> update_event(%{initiative_id: nil, min_age: 30}, ctx.workspace, ctx.admin)

    assert detached.min_age == 30

    assert fields(detached.detached_rule_provenance) == %{
             "min_participants" => %{"value" => 8, "source" => "locked"}
           }
  end

  test "标记读取以锁后行为准：并发已清除的键不会被旧快照复活", ctx do
    initiative =
      initiative(ctx.admin, "detach-marker-race", [:age_gate, :min_participants])

    detached =
      draft_event(ctx.workspace, ctx.admin)
      |> mount(initiative, ctx.workspace, ctx.admin)
      |> detach(ctx.workspace, ctx.admin)

    assert map_size(fields(detached.detached_rule_provenance)) == 2

    # 并发写入已提交（等价于另一管理员在场主改 min_age 时保存）：清掉 min_age 键。
    # 本次 detach 的 changeset 仍持两键旧快照（读 → 加锁窗口）。
    Cgc2046.Repo.query!(
      "UPDATE events SET detached_rule_provenance = detached_rule_provenance #- '{fields,min_age}' WHERE id = $1",
      [Ecto.UUID.dump!(detached.id)]
    )

    written =
      detached
      |> Ash.Changeset.for_update(:update, %{min_participants: 12}, tenant: ctx.workspace.id)
      |> Ash.update!(actor: ctx.admin, tenant: ctx.workspace.id)

    # 标记源 = 锁后读回的库值（只剩 min_participants）→ 本次改写把它清掉 → 整列 nil；
    # 用旧快照读改写会把已被并发清掉的 min_age 复活（本用例即红）
    assert reload(written).detached_rule_provenance == nil
  end

  # ── 验收 3：未标记字段的编辑不动标记 ─────────────────────────────────────

  test "标记值取锁后重读的当前保留值，不取加锁前的 changeset.data（并发写入窗口）", ctx do
    initiative = initiative(ctx.admin, "detach-stale-read", [:age_gate])

    mounted =
      draft_event(ctx.workspace, ctx.admin)
      |> mount(initiative, ctx.workspace, ctx.admin)

    assert mounted.min_age == 18

    # 布置并发写入已提交、而本次 detach 的 changeset 仍持旧快照（读 → 加锁窗口；
    # 锁死规则传播 / 另一管理员字段编辑同款）。直写库 = 布置而非被测对象。
    Cgc2046.Repo.query!("UPDATE events SET min_age = 22 WHERE id = $1", [
      Ecto.UUID.dump!(mounted.id)
    ])

    detached =
      mounted
      |> Ash.Changeset.for_update(:update, %{initiative_id: nil}, tenant: ctx.workspace.id)
      |> Ash.update!(actor: ctx.admin, tenant: ctx.workspace.id)

    # 保留值 = 库中真值（22），不是旧快照（18）——标记必须复述真值，否则读面
    # 会出现「字段 22 + 标记 18」的自相矛盾
    assert reload(detached).min_age == 22

    assert fields(detached.detached_rule_provenance) == %{
             "min_age" => %{"value" => 22, "source" => "locked"}
           }
  end

  test "编辑未标记字段（标题/时间/未锁规则字段）→ 标记原样", ctx do
    initiative = initiative(ctx.admin, "detach-unmarked", [:age_gate])

    detached =
      draft_event(ctx.workspace, ctx.admin)
      |> mount(initiative, ctx.workspace, ctx.admin)
      |> detach(ctx.workspace, ctx.admin)

    assert fields(detached.detached_rule_provenance) == %{
             "min_age" => %{"value" => 18, "source" => "locked"}
           }

    edited =
      update_event(
        detached,
        %{
          title: "改名",
          registration_deadline: EF.days_from_now(5),
          min_participants: 12
        },
        ctx.workspace,
        ctx.admin
      )

    assert edited.detached_rule_provenance == detached.detached_rule_provenance
  end

  # ── 验收 4：重挂载清标记 + 新规则覆盖旧强制值 ─────────────────────────────

  test "重挂载：标记清空 + 新规则按 merge_event_value 生效（旧强制值被覆盖）", ctx do
    old = initiative(ctx.admin, "detach-remount-old", [:age_gate])
    new = initiative(ctx.admin, "detach-remount-new", [:age_gate], %{age_gate: %{min_age: 21}})

    detached =
      draft_event(ctx.workspace, ctx.admin)
      |> mount(old, ctx.workspace, ctx.admin)
      |> detach(ctx.workspace, ctx.admin)

    assert detached.min_age == 18

    assert fields(detached.detached_rule_provenance) == %{
             "min_age" => %{"value" => 18, "source" => "locked"}
           }

    remounted = mount(detached, new, ctx.workspace, ctx.admin)

    assert remounted.initiative_id == new.id
    assert remounted.detached_rule_provenance == nil
    assert reload(remounted).detached_rule_provenance == nil
    # 旧强制值被新 Initiative 的 locked 规则覆盖（值重新归新规则治理）
    assert remounted.min_age == 21
  end

  test "重挂载到全默认规则的 Initiative：标记清空、旧 locked 值被新默认快照覆盖", ctx do
    old = initiative(ctx.admin, "detach-remount-defaults-old", [:age_gate])
    new = initiative(ctx.admin, "detach-remount-defaults-new", [], %{age_gate: %{min_age: 21}})

    remounted =
      draft_event(ctx.workspace, ctx.admin)
      |> mount(old, ctx.workspace, ctx.admin)
      |> detach(ctx.workspace, ctx.admin)
      |> mount(new, ctx.workspace, ctx.admin)

    assert remounted.detached_rule_provenance == nil
    assert remounted.min_age == 21
  end

  # ── 验收 5：无 locked 规则 → detach 标记 nil ─────────────────────────────

  test "无 locked 规则的 Initiative：detach 后标记 nil（默认快照值仍保留）", ctx do
    initiative = initiative(ctx.admin, "detach-no-locked", [])

    detached =
      draft_event(ctx.workspace, ctx.admin)
      |> mount(initiative, ctx.workspace, ctx.admin)
      |> detach(ctx.workspace, ctx.admin)

    assert detached.min_age == 18
    assert detached.min_participants == 8
    assert detached.detached_rule_provenance == nil
  end

  # ── 未挂载场的既有行为不被标记逻辑污染（回归钉） ─────────────────────────

  test "从未挂载的场：普通更新不产生标记、可自由编辑年龄/人数", ctx do
    event = draft_event(ctx.workspace, ctx.admin)
    assert event.detached_rule_provenance == nil

    edited =
      update_event(event, %{min_age: 30, min_participants: 3}, ctx.workspace, ctx.admin)

    assert edited.min_age == 30
    assert edited.min_participants == 3
    assert edited.detached_rule_provenance == nil
  end

  # ── 规则传播只针对挂载中的场（标记必为 nil，无冲突） ─────────────────────

  test "规则传播不触碰已解除挂载场的标记与字段（传播范围 = 挂载中的非终态场）", ctx do
    initiative = initiative(ctx.admin, "detach-propagation", [:min_participants])

    detached =
      draft_event(ctx.workspace, ctx.admin)
      |> mount(initiative, ctx.workspace, ctx.admin)
      |> detach(ctx.workspace, ctx.admin)

    rule =
      InitiativeRule
      |> Ash.Query.filter(initiative_id == ^initiative.id and key == :min_participants)
      |> Ash.read_one!(actor: ctx.admin)

    assert {:ok, _} =
             rule
             |> Ash.Changeset.for_update(:update, %{value: %{count: 99}})
             |> Ash.update(actor: ctx.admin)

    reloaded = reload(detached)
    assert reloaded.min_participants == 8
    assert reloaded.detached_rule_provenance == detached.detached_rule_provenance
  end
end

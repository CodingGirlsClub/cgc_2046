defmodule Cgc2046.InitiativeBoundaryTest do
  use Cgc2046.DataCase, async: true
  use Oban.Testing, repo: Cgc2046.Repo
  require Ash.Query
  alias Cgc2046.AccountsFixtures, as: F
  alias Cgc2046.EventsFixtures, as: EF
  alias Cgc2046.Events.{Event, Qualification}
  alias Cgc2046.Initiatives.{Initiative, InitiativeRule}
  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Payments.Order
  alias Cgc2046.Payments.Workers.PaymentRefundWorker
  alias Cgc2046.Notifications.{Delivery, NotificationDelivery}
  alias Cgc2046.Notifications.Workers.DeliveryWorker

  setup do
    admin = F.platform_admin("initiative-boundary")

    %{
      admin: admin,
      workspace: F.create_workspace(admin),
      learner: F.register_user("initiative-boundary-learner")
    }
  end

  defp initiative(admin, slug \\ "boundary"),
    do: initiative_with_deposit(admin, %{enabled: true, amount_cents: 6900}, slug)

  defp initiative_with_deposit(admin, deposit_value, slug \\ "boundary") do
    i =
      Initiative
      |> Ash.Changeset.for_create(:create, %{
        name: "Boundary",
        slug: slug,
        created_by: admin.id
      })
      |> Ash.create!(actor: admin)

    for {key, value} <- [
          deposit: deposit_value,
          age_gate: %{min_age: 18},
          min_participants: %{count: 8},
          deadline_rule: %{hours_before_start: 72}
        ] do
      InitiativeRule
      |> Ash.Changeset.for_create(:create, %{
        initiative_id: i.id,
        key: key,
        value: value,
        locked: true
      })
      |> Ash.create!(actor: admin)
    end

    i |> Ash.Changeset.for_update(:open, %{}) |> Ash.update!(actor: admin)
  end

  # 草稿态 Event 布置（不过 force_open）：挂载/规则传播的挂载边界要求 draft。
  defp draft_event(workspace, admin, attrs) do
    attrs =
      Map.merge(
        %{
          title: "Boundary Draft",
          enrollment_policy: :open,
          starts_at: DateTime.add(DateTime.utc_now(), 10, :day),
          ends_at: DateTime.add(DateTime.utc_now(), 11, :day)
        },
        attrs
      )

    Event
    |> Ash.Changeset.for_create(:create, attrs, tenant: workspace.id)
    |> Ash.create!(tenant: workspace.id, actor: admin)
  end

  defp enroll(event, learner) do
    Enrollment
    |> Ash.Changeset.for_create(:create_enrollment, %{event_id: event.id, user_id: learner.id})
    |> Ash.create!(actor: learner, tenant: event.workspace_id)
  end

  defp paid_order(e, kind) do
    Order
    |> Ash.Changeset.for_create(:create, %{
      enrollment_id: e.id,
      order_kind: kind,
      provider: :wechat_native,
      out_trade_no: Ecto.UUID.generate(),
      amount_cents: 6900,
      tier_snapshot: %{},
      expire_at: DateTime.add(DateTime.utc_now(), 3600)
    })
    |> Ash.create!(authorize?: false, tenant: e.workspace_id)
    |> Ash.Changeset.for_update(:mark_paid, %{transaction_id: Ecto.UUID.generate()})
    |> Ash.update!(authorize?: false, tenant: e.workspace_id)
  end

  test "closed initiative cannot reopen or close twice", %{admin: admin} do
    i = initiative(admin) |> Ash.Changeset.for_update(:close, %{}) |> Ash.update!(actor: admin)
    assert {:error, _} = i |> Ash.Changeset.for_update(:open, %{}) |> Ash.update(actor: admin)
    assert {:error, _} = i |> Ash.Changeset.for_update(:close, %{}) |> Ash.update(actor: admin)
  end

  test "initiative slug is a URL segment", %{admin: admin} do
    assert {:error, _} =
             Initiative
             |> Ash.Changeset.for_create(:create, %{
               name: "Bad",
               slug: "bad/path",
               created_by: admin.id
             })
             |> Ash.create(actor: admin)
  end

  # ── #588：slug 发布后锁定（draft 可改 / open+closed 锁死 / 无 rename 后门）──

  defp draft_initiative(admin, slug) do
    Initiative
    |> Ash.Changeset.for_create(:create, %{name: "Draft", slug: slug, created_by: admin.id})
    |> Ash.create!(actor: admin)
  end

  defp update_slug(initiative, slug, admin) do
    initiative
    |> Ash.Changeset.for_update(:update, %{slug: slug})
    |> Ash.update(actor: admin)
  end

  test "draft 期改 slug 正常", %{admin: admin} do
    draft = draft_initiative(admin, "slug-lock-draft")

    assert {:ok, renamed} = update_slug(draft, "slug-lock-draft-2", admin)
    assert renamed.slug == "slug-lock-draft-2"
  end

  test "open 后改 slug 被拒：稳定 code initiative_slug_locked + 库中 slug 不变", %{admin: admin} do
    open = initiative(admin, "slug-lock-open")

    assert {:error, %Ash.Error.Invalid{errors: errors} = error} =
             update_slug(open, "slug-lock-open-renamed", admin)

    assert Enum.any?(
             errors,
             &match?(%Cgc2046.Errors.BusinessError{code: "initiative_slug_locked"}, &1)
           )

    assert Exception.message(error) =~ "slug is locked"
    assert Ash.get!(Initiative, open.id, authorize?: false).slug == "slug-lock-open"
  end

  test "closed 后改 slug 仍被拒（终态不可逆，恢复=新建）", %{admin: admin} do
    closed =
      initiative(admin, "slug-lock-closed")
      |> Ash.Changeset.for_update(:close, %{})
      |> Ash.update!(actor: admin)

    assert closed.status == :closed

    assert {:error, error} = update_slug(closed, "slug-lock-closed-2", admin)
    assert Exception.message(error) =~ "slug is locked"
    assert Ash.get!(Initiative, closed.id, authorize?: false).slug == "slug-lock-closed"
  end

  test "open 后改 name/description 且 slug 原样回传：成功（不误触发锁定）", %{admin: admin} do
    open = initiative(admin, "slug-lock-keep")

    # web admin 表单在非 draft 态 disabled 但仍原样回传 form.slug——同值不进
    # changeset.attributes（Ash do_change_attribute 的 equal? 分支），故守卫不触发。
    assert {:ok, updated} =
             open
             |> Ash.Changeset.for_update(:update, %{
               name: "改过的名字",
               description: "改过的描述",
               slug: open.slug
             })
             |> Ash.update(actor: admin)

    assert updated.name == "改过的名字"
    assert updated.description == "改过的描述"
    assert updated.slug == "slug-lock-keep"
  end

  test "非 draft 传「又非法又锁定」的 slug：只回一个错误（锁定优先，不叠加格式错）", %{
    admin: admin
  } do
    open = initiative(admin, "slug-lock-priority")

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             update_slug(open, "Bad Slug", admin)

    assert [%Cgc2046.Errors.BusinessError{code: "initiative_slug_locked"}] = errors
  end

  test "draft 传非法 slug 仍被拒（格式校验未被 only_when_valid? 误关）", %{admin: admin} do
    draft = draft_initiative(admin, "slug-lock-format")

    assert {:error, error} = update_slug(draft, "Bad Slug", admin)
    assert Exception.message(error) =~ "must match"
    assert Ash.get!(Initiative, draft.id, authorize?: false).slug == "slug-lock-format"
  end

  # ── #604：撞 slug 的唯一索引冲突 → 稳定 code，且不回显库内文本 ──
  #
  # 根因与修复：migration 20260913155651 的 `unique_index` 默认名
  # `initiatives_slug_index` 与 identity 推导名 `initiatives_unique_slug_index`
  # 不一致 ⇒ ash_postgres 注册的 `unique_constraint(match: :exact)` 永不匹配，
  # 撞 slug 落 `Ash.Error.Unknown` 且原文含索引名 + 该 changeset 注册的全部约束名
  # （MCP 侧 `Exception.message/1` 直出 ⇒ 真实泄漏）。修复 = 索引改名对齐
  # （20260916130000）+ `Initiative.handle_write_error/2` 映射业务码。
  test "draft 改到已占用 slug：initiative_slug_taken + 无库内文本 + 不落库", %{admin: admin} do
    _taken = draft_initiative(admin, "slug-taken-update")
    draft = draft_initiative(admin, "slug-taken-free")

    assert {:error, %Ash.Error.Invalid{errors: errors} = error} =
             update_slug(draft, "slug-taken-update", admin)

    assert [%Cgc2046.Errors.BusinessError{code: "initiative_slug_taken", fields: [:slug]}] =
             errors

    message = Exception.message(error)
    assert message =~ "slug has already been taken"
    refute message =~ "initiatives_slug_index"
    refute message =~ "initiatives_unique_slug_index"
    refute message =~ "duplicate key"
    refute message =~ "constraint error"
    # Postgres detail（`Key (slug)=(...) already exists.`）同样不得外泄
    refute message =~ "already exists"

    assert Ash.get!(Initiative, draft.id, authorize?: false).slug == "slug-taken-free"
  end

  test "create 撞已占用 slug：initiative_slug_taken + 无库内文本 + 不落库", %{admin: admin} do
    _taken = draft_initiative(admin, "slug-taken-create")

    assert {:error, %Ash.Error.Invalid{errors: errors} = error} =
             Initiative
             |> Ash.Changeset.for_create(:create, %{
               name: "Dup",
               slug: "slug-taken-create",
               created_by: admin.id
             })
             |> Ash.create(actor: admin)

    assert [%Cgc2046.Errors.BusinessError{code: "initiative_slug_taken", fields: [:slug]}] =
             errors

    message = Exception.message(error)
    assert message =~ "slug has already been taken"
    refute message =~ "initiatives_slug_index"
    refute message =~ "initiatives_unique_slug_index"
    refute message =~ "duplicate key"
    refute message =~ "constraint error"
    refute message =~ "already exists"

    rows =
      Ash.read!(Initiative, authorize?: false)
      |> Enum.filter(&(&1.slug == "slug-taken-create"))

    assert length(rows) == 1
  end

  test "open 后改到已占用 slug：锁定优先（initiative_slug_locked）", %{admin: admin} do
    _taken = draft_initiative(admin, "slug-taken-priority-taken")
    open = initiative(admin, "slug-taken-priority-open")

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             update_slug(open, "slug-taken-priority-taken", admin)

    assert [%Cgc2046.Errors.BusinessError{code: "initiative_slug_locked"}] = errors
    assert Ash.get!(Initiative, open.id, authorize?: false).slug == "slug-taken-priority-open"
  end

  # 索引名对齐钉已由全仓守卫取代（#611）：identity 推导名的存在性/唯一性对
  # 42 条 identity 全量断言，见 test/cgc_2046/identity_index_guard_test.exs
  # （DSL → pg_indexes；`generate_migrations --check` 是纯文件比对，抓不到 DB 漂移）。

  # ── #611：同 initiative 同 key 撞唯一索引 → 稳定 code ──
  #
  # 可达面 = 直接 create 重复 (initiative_id, key)（AshAdmin；GraphQL
  # `upsertInitiativeRule` / MCP `admin_upsert_initiative_rule` 是读-后-写，只在并发
  # 窗口撞）。修复 = 索引改名对齐（20260916210000）+
  # `InitiativeRule.handle_write_error/2` 映射业务码。
  test "同 initiative 同 key 重复 create：initiative_rule_already_exists + 无库内文本", %{
    admin: admin
  } do
    i = initiative(admin)

    existing =
      InitiativeRule
      |> Ash.Query.filter(initiative_id == ^i.id and key == :age_gate)
      |> Ash.read_one!(actor: admin)

    assert {:error, %Ash.Error.Invalid{errors: errors} = error} =
             InitiativeRule
             |> Ash.Changeset.for_create(:create, %{
               initiative_id: i.id,
               key: :age_gate,
               value: existing.value,
               locked: existing.locked
             })
             |> Ash.create(actor: admin)

    assert [%Cgc2046.Errors.BusinessError{code: "initiative_rule_already_exists", fields: [:key]}] =
             errors

    message = Exception.message(error)
    assert message =~ "a rule for this initiative and key already exists"
    refute message =~ "initiative_rules_initiative_id_key_index"
    refute message =~ "initiative_rules_unique_initiative_key_index"
    refute message =~ "duplicate key"
    refute message =~ "constraint error"
    # 注：不 refute "already exists"——本 code 的干净文案自身就含该短语
    # （Postgres 的 `Key (…)=(…) already exists.` detail 已被整个替换掉，
    # 泄露面由上面四条索引名/约束文本断言覆盖）

    rows =
      InitiativeRule
      |> Ash.Query.filter(initiative_id == ^i.id and key == :age_gate)
      |> Ash.read!(actor: admin)

    assert length(rows) == 1
  end

  test "enabled deposit rule requires amount", %{admin: admin} do
    i = initiative(admin)

    r =
      InitiativeRule
      |> Ash.Query.filter(initiative_id == ^i.id and key == :deposit)
      |> Ash.read_one!(actor: admin)

    assert {:error, _} =
             r
             |> Ash.Changeset.for_update(:update, %{value: %{enabled: true}})
             |> Ash.update(actor: admin)

    assert Ash.get!(InitiativeRule, r.id, actor: admin).value["amount_cents"] == 6900
  end

  test "published event cannot detach", ctx do
    i = initiative(ctx.admin)

    e =
      EF.create_event(ctx.workspace, ctx.admin, %{
        initiative_id: i.id,
        starts_at: DateTime.add(DateTime.utc_now(), 10, :day),
        ends_at: DateTime.add(DateTime.utc_now(), 11, :day)
      })

    assert {:error, _} =
             e
             |> Ash.Changeset.for_update(:update, %{initiative_id: nil})
             |> Ash.update(actor: ctx.admin, tenant: ctx.workspace.id)
  end

  test "locked fields reject local writes and unrelated editing preserves deadline", ctx do
    i = initiative(ctx.admin)

    e = draft_event(ctx.workspace, ctx.admin, %{initiative_id: i.id})

    assert {:error, _} =
             e
             |> Ash.Changeset.for_update(:update, %{deposit_amount_cents: 1})
             |> Ash.update(actor: ctx.admin, tenant: ctx.workspace.id)

    changed =
      e
      |> Ash.Changeset.for_update(:update, %{title: "Renamed"})
      |> Ash.update!(actor: ctx.admin, tenant: ctx.workspace.id)

    assert changed.registration_deadline == e.registration_deadline
  end

  # U3 / KTD3 / R1：Initiative 押金规则挂载/传播遇已开定价 Event 拒绝，
  # 不静默关闭定价；目标 Event 资金配置不变。
  test "deposit rule mount onto pricing-enabled event is rejected and pricing is preserved",
       ctx do
    i = initiative(ctx.admin)

    e =
      draft_event(ctx.workspace, ctx.admin, %{
        pricing_enabled: true,
        price_tiers: [%{"id" => Ash.UUID.generate(), "name" => "标准", "amount_cents" => 19_900}]
      })

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             e
             |> Ash.Changeset.for_update(:update, %{initiative_id: i.id})
             |> Ash.update(actor: ctx.admin, tenant: ctx.workspace.id)

    assert Enum.any?(
             errors,
             &match?(%Cgc2046.Errors.BusinessError{code: "event_payment_mode_exclusive"}, &1)
           ),
           "expected event_payment_mode_exclusive, got: #{inspect(errors)}"

    reloaded = Ash.get!(Event, e.id, authorize?: false)
    assert reloaded.pricing_enabled == true
    assert reloaded.price_tiers == e.price_tiers
    assert reloaded.deposit_enabled == false
    assert reloaded.initiative_id == nil
  end

  # U3 / KTD3 传播路径：押金规则由关转开传播到已挂载 Event 时，遇已开定价
  # 的 Event 拒绝整次规则更新（规则行与目标 Event 同事务回滚）。
  test "deposit rule propagation stops when a mounted event has pricing enabled", ctx do
    i = initiative_with_deposit(ctx.admin, %{enabled: false, amount_cents: nil})

    e =
      draft_event(ctx.workspace, ctx.admin, %{initiative_id: i.id})

    assert e.deposit_enabled == false

    # 押金关闭态下开定价合法（互斥只管双真）
    assert {:ok, priced} =
             e
             |> Ash.Changeset.for_update(:update, %{
               pricing_enabled: true,
               price_tiers: [
                 %{"id" => Ash.UUID.generate(), "name" => "标准", "amount_cents" => 19_900}
               ]
             })
             |> Ash.update(actor: ctx.admin, tenant: ctx.workspace.id)

    r =
      InitiativeRule
      |> Ash.Query.filter(initiative_id == ^i.id and key == :deposit)
      |> Ash.read_one!(actor: ctx.admin)

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             r
             |> Ash.Changeset.for_update(:update, %{value: %{enabled: true, amount_cents: 6900}})
             |> Ash.update(actor: ctx.admin)

    assert Enum.any?(
             errors,
             &match?(%Cgc2046.Errors.BusinessError{code: "event_payment_mode_exclusive"}, &1)
           ),
           "expected event_payment_mode_exclusive, got: #{inspect(errors)}"

    reloaded_rule = Ash.get!(InitiativeRule, r.id, actor: ctx.admin)
    assert reloaded_rule.value == %{"enabled" => false, "amount_cents" => nil}

    reloaded_event = Ash.get!(Event, e.id, authorize?: false)
    assert reloaded_event.pricing_enabled == true
    assert reloaded_event.price_tiers == priced.price_tiers
    assert reloaded_event.deposit_enabled == false
  end

  # #608：押金规则挂载到没有 ends_at 的场 → DB CHECK
  # `events_deposit_requires_ends_at` 拒绝（修复前静默建成「押金开 + 无结算锚点」），
  # 并经 handle_write_error/2 映射回同源业务码。挂载路径在 before_action force 押金
  # 字段、资源级 validate 先于 before_action 执行看不见它，ends_at 又无 RuleInheritance
  # 前置守卫（收口评估见 #634）→ 兜底只能由 DB CHECK 承担。
  test "deposit rule mount onto an event without ends_at is rejected by the DB CHECK", ctx do
    i = initiative(ctx.admin)

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Event
             |> Ash.Changeset.for_create(
               :create,
               %{
                 title: "无结算锚点的草稿场",
                 enrollment_policy: :open,
                 starts_at: DateTime.add(DateTime.utc_now(), 10, :day),
                 ends_at: nil,
                 initiative_id: i.id
               },
               tenant: ctx.workspace.id
             )
             |> Ash.create(actor: ctx.admin, tenant: ctx.workspace.id)

    assert Enum.any?(
             errors,
             &match?(%Cgc2046.Errors.BusinessError{code: "event_deposit_ends_at_required"}, &1)
           ),
           "expected event_deposit_ends_at_required, got: #{inspect(errors)}"

    assert Ash.read!(Event, authorize?: false) == []
  end

  # #597 I2：押金规则挂载遇目标 Event 有「档位残留」（定价关闭但档位非空，R4 合法
  # 休眠态）→ 拒绝并给出补救动作；档位与押金状态原样，未挂载。
  # 该路径在 before_action 里 force_change deposit 字段，资源级 validate 先于
  # before_action 执行 → 拒绝必须由 RuleInheritance 自己给出（DB CHECK 是最后兜底）。
  test "deposit rule mount onto an event with dormant price tiers is rejected", ctx do
    i = initiative(ctx.admin)

    e =
      draft_event(ctx.workspace, ctx.admin, %{
        price_tiers: [%{"id" => Ash.UUID.generate(), "name" => "休眠", "amount_cents" => 9900}]
      })

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             e
             |> Ash.Changeset.for_update(:update, %{initiative_id: i.id})
             |> Ash.update(actor: ctx.admin, tenant: ctx.workspace.id)

    assert Enum.any?(
             errors,
             &match?(
               %Cgc2046.Errors.BusinessError{code: "event_deposit_price_tiers_conflict"},
               &1
             )
           ),
           "expected event_deposit_price_tiers_conflict, got: #{inspect(errors)}"

    # 文案钉死「规则路径判据本体」：DB CHECK 兜底映射的是域文案
    # （"price tiers must be empty..."），本条是 RuleInheritance 自己的补救指引。
    assert Enum.any?(errors, fn
             %Cgc2046.Errors.BusinessError{message: msg} ->
               msg =~ "clear price tiers before applying the deposit rule"

             _ ->
               false
           end)

    reloaded = Ash.get!(Event, e.id, authorize?: false)
    assert reloaded.price_tiers == e.price_tiers
    assert reloaded.deposit_enabled == false
    assert reloaded.initiative_id == nil
  end

  # #597 I2 传播路径（裸 SQL）：押金规则由关转开传播遇已挂载 Event 有档位残留 →
  # 拒绝整次规则更新（规则行与全部已挂载 Event 同事务回滚），档位保留。
  test "deposit rule propagation stops when a mounted event keeps dormant price tiers", ctx do
    i = initiative_with_deposit(ctx.admin, %{enabled: false, amount_cents: nil})

    e =
      draft_event(ctx.workspace, ctx.admin, %{
        initiative_id: i.id,
        price_tiers: [%{"id" => Ash.UUID.generate(), "name" => "休眠", "amount_cents" => 9900}]
      })

    assert e.deposit_enabled == false
    assert e.price_tiers != []

    r =
      InitiativeRule
      |> Ash.Query.filter(initiative_id == ^i.id and key == :deposit)
      |> Ash.read_one!(actor: ctx.admin)

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             r
             |> Ash.Changeset.for_update(:update, %{value: %{enabled: true, amount_cents: 6900}})
             |> Ash.update(actor: ctx.admin)

    assert Enum.any?(
             errors,
             &match?(
               %Cgc2046.Errors.BusinessError{code: "event_deposit_price_tiers_conflict"},
               &1
             )
           ),
           "expected event_deposit_price_tiers_conflict, got: #{inspect(errors)}"

    reloaded_rule = Ash.get!(InitiativeRule, r.id, actor: ctx.admin)
    assert reloaded_rule.value == %{"enabled" => false, "amount_cents" => nil}

    reloaded_event = Ash.get!(Event, e.id, authorize?: false)
    assert reloaded_event.price_tiers == e.price_tiers
    assert reloaded_event.deposit_enabled == false
  end

  # #597 I2 的 `enabling?` gate：规则改成 enabled: false 不可能造出违规，不该被
  # 档位残留误拒（规则 update 的 after_action 无条件触发传播）。
  test "deposit rule update to enabled: false is not blocked by dormant price tiers", ctx do
    i = initiative_with_deposit(ctx.admin, %{enabled: false, amount_cents: nil})

    e =
      draft_event(ctx.workspace, ctx.admin, %{
        initiative_id: i.id,
        price_tiers: [%{"id" => Ash.UUID.generate(), "name" => "休眠", "amount_cents" => 9900}]
      })

    assert e.deposit_enabled == false

    r =
      InitiativeRule
      |> Ash.Query.filter(initiative_id == ^i.id and key == :deposit)
      |> Ash.read_one!(actor: ctx.admin)

    assert {:ok, updated_rule} =
             r
             |> Ash.Changeset.for_update(:update, %{value: %{enabled: false, amount_cents: nil}})
             |> Ash.update(actor: ctx.admin)

    assert updated_rule.value == %{"enabled" => false, "amount_cents" => nil}
    assert Ash.get!(Event, e.id, authorize?: false).price_tiers == e.price_tiers
  end

  # #623：押金×定价互斥的同一个 `enabling?` gate。规则改成 enabled: false 不可能
  # 造出双真，不该被「已开定价的场」误拒——否则同一组字段走挂载/编辑被允许、
  # 走传播被拒，规则永远改不动且报错（"disable pricing before applying the
  # deposit rule"）不可操作。传播 after_action 无条件触发，故这里必然经过守卫。
  test "deposit rule update to enabled: false is not blocked by pricing-enabled events", ctx do
    i = initiative_with_deposit(ctx.admin, %{enabled: false, amount_cents: nil})

    e = draft_event(ctx.workspace, ctx.admin, %{initiative_id: i.id})

    # 押金关闭态下开定价合法（互斥只管双真）
    assert {:ok, _priced} =
             e
             |> Ash.Changeset.for_update(:update, %{
               pricing_enabled: true,
               price_tiers: [
                 %{"id" => Ash.UUID.generate(), "name" => "标准", "amount_cents" => 19_900}
               ]
             })
             |> Ash.update(actor: ctx.admin, tenant: ctx.workspace.id)

    r =
      InitiativeRule
      |> Ash.Query.filter(initiative_id == ^i.id and key == :deposit)
      |> Ash.read_one!(actor: ctx.admin)

    assert {:ok, updated_rule} =
             r
             |> Ash.Changeset.for_update(:update, %{value: %{enabled: false, amount_cents: 1200}})
             |> Ash.update(actor: ctx.admin)

    assert updated_rule.value == %{"enabled" => false, "amount_cents" => 1200}

    # 传播确实落库（不是「通过但没写」），定价与押金状态不变
    reloaded = Ash.get!(Event, e.id, authorize?: false)
    assert reloaded.deposit_enabled == false
    assert reloaded.deposit_amount_cents == 1200
    assert reloaded.pricing_enabled == true
  end

  # 回归 Initiative 计划 R7：押金规则挂载到免费 Event 写入押金两列。
  test "deposit rule mount onto free event writes both deposit columns", ctx do
    i = initiative(ctx.admin)

    e = draft_event(ctx.workspace, ctx.admin, %{initiative_id: i.id})

    assert e.deposit_enabled == true
    assert e.deposit_amount_cents == 6900
    assert e.pricing_enabled == false
  end

  # 回归：锁死押金场 Event 侧改押金金额仍被锁死守卫拒绝。
  test "locked deposit field still rejects local amount edits", ctx do
    i = initiative(ctx.admin)

    e = draft_event(ctx.workspace, ctx.admin, %{initiative_id: i.id})

    assert {:error, _} =
             e
             |> Ash.Changeset.for_update(:update, %{deposit_amount_cents: 100})
             |> Ash.update(actor: ctx.admin, tenant: ctx.workspace.id)

    assert Ash.get!(Event, e.id, authorize?: false).deposit_amount_cents == 6900
  end

  test "locked deadline propagation accepts database timestamps", ctx do
    i = initiative(ctx.admin)

    e =
      EF.create_event(ctx.workspace, ctx.admin, %{
        initiative_id: i.id,
        starts_at: DateTime.add(DateTime.utc_now(), 10, :day),
        ends_at: DateTime.add(DateTime.utc_now(), 11, :day)
      })

    r =
      InitiativeRule
      |> Ash.Query.filter(initiative_id == ^i.id and key == :deadline_rule)
      |> Ash.read_one!(actor: ctx.admin)

    assert {:ok, _} =
             r
             |> Ash.Changeset.for_update(:update, %{value: %{hours_before_start: 48}})
             |> Ash.update(actor: ctx.admin)

    assert Ash.get!(Event, e.id, authorize?: false).registration_deadline ==
             DateTime.add(e.starts_at, -48, :hour)
  end

  test "qualification cannot run before deadline", ctx do
    e = EF.create_event(ctx.workspace, ctx.admin, %{min_participants: 2})
    assert :skip = Qualification.qualify(e)
    assert Ash.get!(Event, e.id, authorize?: false).qualification_status == :pending
  end

  test "self cancellation before deadline starts exactly one deposit refund", ctx do
    event =
      EF.create_event(ctx.workspace, ctx.admin, %{
        deposit_enabled: true,
        deposit_amount_cents: 6900,
        ends_at: DateTime.add(DateTime.utc_now(), 10, :day)
      })

    e = enroll(event, ctx.learner)
    order = paid_order(e, :deposit)

    assert {:ok, _} =
             e
             |> Ash.Changeset.for_update(:cancel, %{})
             |> Ash.update(actor: ctx.learner, tenant: ctx.workspace.id)

    assert EF.ledger_occupancy(event) == 0
    assert Ash.get!(Order, order.id, authorize?: false).status == :refunding
    assert [%{args: %{"order_id" => id}}] = all_enqueued(worker: PaymentRefundWorker)
    assert id == order.id

    assert {:error, _} =
             e
             |> Ash.Changeset.for_update(:cancel, %{})
             |> Ash.update(actor: ctx.learner, tenant: ctx.workspace.id)

    assert length(all_enqueued(worker: PaymentRefundWorker)) == 1
  end

  test "after deadline cancellation and ordinary tickets do not refund", ctx do
    event = EF.create_event(ctx.workspace, ctx.admin)
    e = enroll(event, ctx.learner)
    order = paid_order(e, :deposit)

    Cgc2046.Repo.query!(
      "UPDATE events SET registration_deadline = NOW() - INTERVAL '1 hour' WHERE id = $1",
      [Ecto.UUID.dump!(event.id)]
    )

    assert {:ok, _} =
             e
             |> Ash.Changeset.for_update(:cancel, %{})
             |> Ash.update(actor: ctx.learner, tenant: ctx.workspace.id)

    assert Ash.get!(Order, order.id, authorize?: false).status == :paid
    assert EF.ledger_occupancy(event) == 0
    assert all_enqueued(worker: PaymentRefundWorker) == []
  end

  test "repeated schedule edits each have their own durable signal", ctx do
    e = EF.create_event(ctx.workspace, ctx.admin)

    for days <- [3, 4] do
      e
      |> Ash.Changeset.for_update(:update, %{
        starts_at: DateTime.add(DateTime.utc_now(), days, :day)
      })
      |> Ash.update!(actor: ctx.admin, tenant: ctx.workspace.id)
    end

    jobs =
      all_enqueued(worker: Cgc2046.Workflows.SignalPublishWorker)
      |> Enum.filter(&(&1.args["signal_type"] == "event.schedule_changed"))

    assert length(jobs) == 2
    assert length(Enum.uniq_by(jobs, & &1.args["data"]["idempotency_key"])) == 2
    assert all_enqueued(worker: PaymentRefundWorker) == []
  end

  test "notification string platform resolves configured template and waits for consent", ctx do
    assert :ok =
             Delivery.enqueue(
               {ctx.learner.id, [%{provider: :wechat, uid: "boundary-openid"}]},
               "approval_result",
               %{},
               %{"idempotency_key" => "boundary-consent"}
             )

    [row] = Ash.read!(NotificationDelivery, authorize?: false)
    assert {:error, :consent_exhausted} = perform_job(DeliveryWorker, %{"delivery_id" => row.id})
    assert Ash.get!(NotificationDelivery, row.id, authorize?: false).status == :pending
  end

  test "replayed notification enqueue is idempotent", ctx do
    for _ <- 1..2,
        do:
          Delivery.enqueue({ctx.learner.id, []}, "event_schedule_changed", %{}, %{
            "idempotency_key" => "boundary-replay"
          })

    assert length(Ash.read!(NotificationDelivery, authorize?: false)) == 1

    assert [only] = Ash.read!(NotificationDelivery, authorize?: false)
    assert length(all_enqueued(worker: DeliveryWorker, args: %{"delivery_id" => only.id})) == 1
  end
end

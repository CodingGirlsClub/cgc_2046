defmodule Cgc2046.Initiatives.RuleInheritance do
  @moduledoc """
  Event 与 InitiativeRule 的挂载边界。

  所有挂载和 Event 规则写入先锁 Initiative 行，再读取规则；这保证规则翻锁与
  Owner/Admin 的草稿写入不会在 READ COMMITTED 下互相覆盖。

  ## 锁死规则传播的契约（issue #587）

  规则写入有两条路径——挂载合并 `prepare_event_changes/2` 与锁死项传播
  `propagate_rule_change/4`（后者在规则行所在事务内把锁死项写到全部挂载场）
  ——共同遵守六条不变量：

  1. **范围**：只传播到非终态场（`draft` / `open`）。`closed` / `cancelled`
     是历史事实（D4 终态不可逆），规则变更不回溯改写它们的字段、账本缓存
     与审计面。
  2. **不变量守卫**：规则写入不得把某场从「满足押金不变量」翻成
     「`deposit_enabled = true` 且 `registration_deadline` 为空」——挂载路径
     （`prepare_event_changes/2`）与传播路径共用同一判定，违规即**拒绝整次
     规则更新**（不静默跳过：跳过会让「锁死 = 全场生效」失真；错误 `fields`
     带 `event_id` 供定位）。只拦**本次写入造成**的新违规，已存在的脏态不
     阻断无关规则变更。
     **本不变量只覆盖 `registration_deadline`**：押金的另外两个写面要求
     （`ends_at` 非空 = no-show 结算锚点、`deposit_amount_cents` 为正）仍只由
     Event 写面校验（`Events.PaymentModeValidation`）与对账
     `deposit_settlement_unanchored` 看护——规则的挂载/传播路径不拦它们。
  3. **账本同事务同步**：`deadline_rule` 写的是报名截止，而报名截止的执法读
     名额账本缓存列（`Admission.CapacityLedger.reserve/2` 三守卫之一），故
     传播在同一事务内逐场直连 `CapacityLedger.sync_offering_cache/1`。
     **有意不发** `offering.capacity_changed`：该信号经 Oban outbox 异步投递，
     满足不了同事务收敛，且其唯一订阅方就是账本本身。规则传播是**有意的
     静默路径**——新增订阅方必须显式把本路径纳入。
  4. **不重算成班事实**：改 `min_participants` 只写 `events.min_participants`，
     不触碰 `qualification_status`（成班是到点一次性 CAS 落定的事实，
     `Events.Qualification` 明确不可逆；重算涉及撤销事实 / 通知重发 / 核销与
     退款回溯，属另一 issue）。未到点的场自然按新阈值判定。
  5. **押金 × 定价互斥**：挂载 / 锁死合并的判据是 `deposit_enabled AND
     pricing_enabled` 双真（同 DB CHECK `events_payment_mode_exclusive`）；
     押金规则**关闭态**（`enabled: false`）不参与互斥——`pricing=true` +
     `deposit=false` 是合法态，关闭态规则写入只是幂等回写。
     传播前置守卫 `ensure_pricing_exclusive/2` 另有更保守的**既有**语义
     （KTD3/R1「不静默关闭定价」，issue #587 未改动）：锁死 deposit 规则的
     **任何**变更（含关闭态）遇在范围内已开定价的场即拒绝整次规则更新。
  6. **押金 × 档位残留（#597）**：押金规则**开启**时，目标场 `price_tiers`
     必须为空——档位有内容会让按 `tiers` 分支的读面与按 `deposit_enabled`
     分支的读面自相矛盾（`Events.PaymentModeValidation` moduledoc 记录 #586
     的实测后果）。挂载合并与传播路径共用同一判定，违规即拒绝整次规则更新
     （错误 `fields` 带 `event_id`）。规则**关闭态不参与**：`pricing=false` +
     档位非空是 R4 合法休眠态，不阻断关闭写入。并发兜底 = DB CHECK
     `events_deposit_excludes_price_tiers`。
  """

  alias Cgc2046.Admission.CapacityLedger
  alias Cgc2046.Events.PaymentModeValidation
  alias Cgc2046.Repo

  @rule_keys [:deposit, :age_gate, :min_participants, :deadline_rule]

  @doc "应用 Event create/update changeset 中的挂载规则与锁死守卫。"
  def prepare_event_changes(changeset, _context) do
    previous_id = Ash.Changeset.get_data(changeset, :initiative_id)
    initiative_id = Ash.Changeset.get_attribute(changeset, :initiative_id)
    mounting? = Ash.Changeset.changing_attribute?(changeset, :initiative_id)

    # Lock both parents in stable order before the Event, including detach.
    with :ok <- lock_parents([previous_id, initiative_id]),
         :ok <- lock_current_event(changeset),
         :ok <- ensure_mount_state(changeset) do
      if is_nil(initiative_id) do
        changeset
      else
        with {:ok, initiative} <- lock_initiative(initiative_id),
             :ok <- ensure_open_when_mounting(initiative, mounting?),
             {:ok, rules} <- load_rules(initiative_id),
             :ok <- ensure_complete(rules),
             {:ok, attrs} <- effective_event_attrs(changeset, rules) do
          attrs
          |> Enum.reduce(changeset, fn {field, value}, cs ->
            Ash.Changeset.force_change_attribute(cs, field, value)
          end)
          |> ensure_rule_deposit_invariant()
        else
          {:error, message} -> Ash.Changeset.add_error(changeset, message)
        end
      end
    else
      {:error, message} -> Ash.Changeset.add_error(changeset, message)
    end
  end

  defp lock_parents(ids) do
    ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn id, :ok ->
      case lock_initiative(id) do
        {:ok, _} -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp lock_current_event(%{action_type: :create}), do: :ok

  defp lock_current_event(changeset) do
    case Repo.query("SELECT initiative_id, status FROM events WHERE id = $1 FOR UPDATE", [
           Repo.uuid!(changeset.data.id)
         ]) do
      {:ok, %{rows: [[parent_id, status]]}} ->
        parent_id = if parent_id, do: Ecto.UUID.load!(parent_id)

        if parent_id == changeset.data.initiative_id and
             status == to_string(changeset.data.status),
           do: :ok,
           else: {:error, "event changed; reload before editing"}

      _ ->
        {:error, "event not found"}
    end
  end

  def prepare_rule_change(changeset) do
    with {:ok, _} <- lock_initiative(Ash.Changeset.get_attribute(changeset, :initiative_id)),
         :ok <-
           validate_rule_value(
             Ash.Changeset.get_attribute(changeset, :key),
             Ash.Changeset.get_attribute(changeset, :value)
           ) do
      changeset
    else
      {:error, message} -> Ash.Changeset.add_error(changeset, message)
    end
  end

  @doc """
  规则值或锁标记改变后，锁死项传播到全部**非终态**已挂载 Event（`draft` /
  `open`；`closed` / `cancelled` 不动）。调用方应在 Ash action 事务内执行。

  六条契约见 moduledoc。失败语义：任一场触发守卫即抛错，规则行与全部场的
  写入同事务回滚（不部分生效）。
  """
  def propagate_rule_change(initiative_id, key, value, locked) do
    with {:ok, _initiative} <- lock_initiative(initiative_id),
         {:ok, key_atom} <- normalize_key(key),
         :ok <- validate_rule_value(key_atom, value) do
      if locked do
        events = lock_propagatable_events(initiative_id)

        # 前置守卫全量过一遍再写（不留「前面几场已改、后面被拒」的中间态给
        # 读者；事务回滚只是兜底）。顺序：押金×定价（KTD3/R1）→ 押金×档位残留
        # （#597）→ 押金不变量（#587）。
        :ok = ensure_pricing_exclusive(events, key_atom)
        :ok = ensure_tiers_empty(events, key_atom, value)

        propagated =
          Enum.map(events, fn event ->
            {event, propagated_attrs(key_atom, value, event.starts_at)}
          end)

        :ok = ensure_deposit_invariant(propagated)

        Enum.each(propagated, fn {event, attrs} -> write_propagated(event, attrs, key_atom) end)
      end

      :ok
    end
  catch
    {:deposit_conflicts_pricing, error} ->
      {:error, error}

    {:deposit_tiers_conflict, error} ->
      {:error, error}

    {:deposit_invariant_conflict, error} ->
      {:error, error}

    {:propagation_error, reason} ->
      {:error, "initiative rule propagation failed: #{inspect(reason)}"}
  end

  # 传播范围：非终态场。closed / cancelled 是历史事实，规则变更不回溯改写
  # （issue #587 验收 3）。ORDER BY id 让加锁顺序确定、报错定位稳定。
  # tiers_present 在 SQL 侧判定（与 DB CHECK 同一判据，且不依赖 jsonb 解码形态）：
  # price_tiers 列 NOT NULL DEFAULT '[]'::jsonb（#597）。
  defp lock_propagatable_events(initiative_id) do
    case Repo.query(
           """
           SELECT id, starts_at, pricing_enabled, deposit_enabled, registration_deadline,
                  status, capacity, workspace_id,
                  (price_tiers <> '[]'::jsonb) AS tiers_present
           FROM events
           WHERE initiative_id = $1 AND status IN ('draft', 'open')
           ORDER BY id
           FOR UPDATE
           """,
           [Repo.uuid!(initiative_id)]
         ) do
      {:ok, %{rows: rows}} -> Enum.map(rows, &event_row/1)
      {:error, reason} -> throw({:propagation_error, reason})
    end
  end

  # 裸 SQL 行 → 具名 map；uuid 列解回字符串（错误 fields 与账本入口都按字符串
  # 形状消费，`Repo.uuid!/1` 只接受字符串）。
  defp event_row([
         id,
         starts_at,
         pricing_enabled,
         deposit_enabled,
         registration_deadline,
         status,
         capacity,
         workspace_id,
         tiers_present
       ]) do
    %{
      id: Ecto.UUID.load!(id),
      starts_at: starts_at,
      pricing_enabled: pricing_enabled,
      deposit_enabled: deposit_enabled,
      registration_deadline: registration_deadline,
      status: status,
      capacity: capacity,
      workspace_id: Ecto.UUID.load!(workspace_id),
      tiers_present: tiers_present
    }
  end

  # KTD3 / R1：押金规则传播遇已开定价的 Event → 拒绝整次规则更新（规则行
  # 与全部挂载 Event 同事务回滚），不静默关闭定价。扫描集合 = 传播集合
  # （终态定价场不再阻断规则变更——它本来就不会被写）。
  defp ensure_pricing_exclusive(_events, key_atom) when key_atom != :deposit, do: :ok

  defp ensure_pricing_exclusive(events, :deposit) do
    case Enum.find(events, & &1.pricing_enabled) do
      nil ->
        :ok

      event ->
        throw({:deposit_conflicts_pricing, pricing_conflict_error(event_id: event.id)})
    end
  end

  # #597：押金规则**开启**时目标场 `price_tiers` 必须为空（读面按档位内容分支
  # 会与押金展示自相矛盾）。gate 在规则值 `enabled: true`：关闭态不参与——
  # 档位残留（`pricing=false` + 档位非空，R4 合法休眠态）不阻断关闭写入。
  # 扫描集合 = 传播集合（终态场不被写，其残留不影响本次写入）。
  defp ensure_tiers_empty(_events, key_atom, _value) when key_atom != :deposit, do: :ok

  defp ensure_tiers_empty(events, :deposit, value) do
    if deposit_enabling?(value) do
      case Enum.find(events, & &1.tiers_present) do
        nil -> :ok
        event -> throw({:deposit_tiers_conflict, tiers_conflict_error(event_id: event.id)})
      end
    else
      :ok
    end
  end

  # 押金不变量（issue #587）：`deposit_enabled = true` 的场必须有非空
  # `registration_deadline`（自助取消锚点）。只拦本次规则写入**新造成**的违规
  # ——已存在的脏态（历史挂载 / 直接编辑造成）不阻断无关规则变更，否则这些
  # Initiative 会被规则永久锁死（同 `PaymentModeValidation.deposit_config_touched?`
  # 「存量行不被无关编辑锁死」纪律）。
  defp ensure_deposit_invariant(propagated) do
    Enum.each(propagated, fn {event, attrs} ->
      before = %{
        deposit_enabled: event.deposit_enabled,
        registration_deadline: event.registration_deadline
      }

      after_state = %{
        deposit_enabled: Map.get(attrs, :deposit_enabled, event.deposit_enabled),
        registration_deadline: Map.get(attrs, :registration_deadline, event.registration_deadline)
      }

      if not deposit_invariant_broken?(before) and deposit_invariant_broken?(after_state) do
        throw(
          {:deposit_invariant_conflict,
           PaymentModeValidation.registration_deadline_required_error(event_id: event.id)}
        )
      end
    end)
  end

  defp deposit_invariant_broken?(%{deposit_enabled: true, registration_deadline: nil}), do: true
  defp deposit_invariant_broken?(_state), do: false

  # 规则写入（挂载 / 锁死项 force）后检查同一条不变量：不得把 Event 从满足
  # 翻成违规。判据源是 changeset 的写前（data）与写后（attribute）状态——
  # 规则值在 before_action 里 force，域校验看不见它们（Ash 资源校验在
  # changeset 构建期执行），故此处必须显式判。
  defp ensure_rule_deposit_invariant(changeset) do
    before = %{
      deposit_enabled: Ash.Changeset.get_data(changeset, :deposit_enabled),
      registration_deadline: Ash.Changeset.get_data(changeset, :registration_deadline)
    }

    after_state = %{
      deposit_enabled: Ash.Changeset.get_attribute(changeset, :deposit_enabled),
      registration_deadline: Ash.Changeset.get_attribute(changeset, :registration_deadline)
    }

    if not deposit_invariant_broken?(before) and deposit_invariant_broken?(after_state) do
      Ash.Changeset.add_error(
        changeset,
        PaymentModeValidation.registration_deadline_required_error(
          rule_invariant_error_fields(changeset)
        )
      )
    else
      changeset
    end
  end

  # create 时 Event 尚无 id（data.id = nil）→ 退回默认 fields（无场可指）。
  defp rule_invariant_error_fields(changeset) do
    case Ash.Changeset.get_data(changeset, :id) do
      nil -> [:registration_deadline]
      id -> [event_id: id]
    end
  end

  # 单场写入：UPDATE … RETURNING 拿同事务权威值；deadline_rule 是唯一会动
  # 账本缓存列的规则 key（`registration_deadline`），逐场把三列缓存覆盖式
  # 回写（occupancy / sync_version 不动）。capacity / status 不由规则改写，
  # 但 RETURNING 值即真值，覆盖写顺带收敛并发漂移。
  defp write_propagated(event, attrs, key_atom) do
    case Repo.query(update_sql(attrs), update_params(Repo.uuid!(event.id), attrs)) do
      {:ok, %{rows: [[workspace_id, status, capacity, registration_deadline]]}} ->
        if key_atom == :deadline_rule do
          sync_ledger_cache(event, %{
            workspace_id: Ecto.UUID.load!(workspace_id),
            status: status,
            capacity: capacity,
            registration_deadline: registration_deadline
          })
        end

        :ok

      {:error, reason} ->
        throw({:propagation_error, reason})
    end
  end

  defp sync_ledger_cache(event, updated) do
    case CapacityLedger.sync_offering_cache(%{
           kind: :event,
           offering_id: event.id,
           workspace_id: updated.workspace_id,
           status: updated.status,
           capacity: updated.capacity,
           registration_deadline: updated.registration_deadline
         }) do
      :ok -> :ok
      {:error, reason} -> throw({:propagation_error, reason})
    end
  end

  defp normalize_key(key) when is_atom(key) and key in @rule_keys, do: {:ok, key}

  defp normalize_key(key) when is_binary(key),
    do:
      if(key in ~w(deposit age_gate min_participants deadline_rule),
        do: {:ok, String.to_existing_atom(key)},
        else: {:error, "invalid rule key"}
      )

  defp normalize_key(_), do: {:error, "invalid rule key"}

  def validate_rule_value(key, value) do
    case value_for_event(key, value, %{attributes: %{starts_at: nil}}) do
      {:ok, _} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  defp propagated_attrs(:deposit, value, _starts_at) do
    {:ok, attrs} = value_for_event(:deposit, value, nil)
    attrs
  end

  defp propagated_attrs(:age_gate, value, _starts_at),
    do: %{min_age: elem(value_for_event(:age_gate, value, nil), 1)}

  defp propagated_attrs(:min_participants, value, _starts_at),
    do: %{min_participants: elem(value_for_event(:min_participants, value, nil), 1)}

  defp propagated_attrs(:deadline_rule, value, starts_at) do
    hours = Map.get(value, "hours_before_start", Map.get(value, :hours_before_start))

    %{
      registration_deadline:
        if(starts_at, do: NaiveDateTime.add(starts_at, -hours * 3600, :second), else: nil)
    }
  end

  # RETURNING 恒带账本缓存三列 + workspace_id：deadline_rule 用它把权威值交给
  # 同事务的账本回写（其余 key 忽略返回值）。列集随 key 变（Map.keys 与
  # Map.values 同序），故仍是每场一条语句。
  defp update_sql(attrs) do
    columns =
      attrs
      |> Map.keys()
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {key, index} -> "#{key} = $#{index}" end)

    """
    UPDATE events SET #{columns}, updated_at = NOW() WHERE id = $#{map_size(attrs) + 1}
    RETURNING workspace_id, status, capacity, registration_deadline
    """
  end

  defp update_params(id, attrs), do: Map.values(attrs) ++ [id]

  @doc "读取某 Initiative 的规则；仅用于公开的规则服务，不返回凭证。"
  def rules_for(initiative_id) when is_binary(initiative_id) do
    case load_rules(initiative_id) do
      {:ok, rules} -> {:ok, rules}
      {:error, _} = error -> error
    end
  end

  @doc "判断 Initiative 是否具备全部四项规则。"
  def ready?(initiative_id) do
    case rules_for(initiative_id) do
      {:ok, rules} -> Enum.all?(@rule_keys, &Map.has_key?(rules, &1))
      _ -> false
    end
  end

  defp lock_initiative(id) do
    case Repo.query("SELECT id, status FROM initiatives WHERE id = $1 FOR UPDATE", [
           Repo.uuid!(id)
         ]) do
      {:ok, %{rows: [[id, status]]}} -> {:ok, %{id: id, status: status}}
      {:ok, %{rows: []}} -> {:error, "initiative not found"}
      {:error, reason} -> {:error, "initiative read failed: #{inspect(reason)}"}
    end
  end

  defp ensure_open(%{status: "open"}), do: :ok
  defp ensure_open(%{status: :open}), do: :ok
  defp ensure_open(_), do: {:error, "initiative must be open before an event can be mounted"}

  defp ensure_open_when_mounting(initiative, true), do: ensure_open(initiative)
  defp ensure_open_when_mounting(_initiative, false), do: :ok

  defp ensure_mount_state(changeset) do
    status = Ash.Changeset.get_data(changeset, :status)
    changing_mount? = Ash.Changeset.changing_attribute?(changeset, :initiative_id)

    cond do
      changing_mount? and status not in [nil, :draft, "draft"] ->
        {:error, "initiative can only be mounted or changed while event is draft"}

      true ->
        :ok
    end
  end

  defp load_rules(initiative_id) do
    result =
      Repo.query(
        "SELECT key, value, locked FROM initiative_rules WHERE initiative_id = $1 ORDER BY key",
        [Repo.uuid!(initiative_id)]
      )

    case result do
      {:ok, %{rows: rows}} ->
        rules =
          Map.new(rows, fn [key, value, locked] ->
            {String.to_existing_atom(key), %{value: value || %{}, locked: locked}}
          end)

        {:ok, rules}

      {:error, reason} ->
        {:error, "initiative rules read failed: #{inspect(reason)}"}
    end
  end

  defp ensure_complete(rules) do
    case @rule_keys -- Map.keys(rules) do
      [] -> :ok
      missing -> {:error, "initiative is missing rules: #{Enum.join(missing, ", ")}"}
    end
  end

  defp effective_event_attrs(changeset, rules) do
    creating? = changeset.action_type == :create
    mounting? = creating? or Ash.Changeset.changing_attribute?(changeset, :initiative_id)

    Enum.reduce_while(@rule_keys, {:ok, %{}}, fn key, {:ok, attrs} ->
      rule = Map.get(rules, key)
      event_field = event_field(key)

      cond do
        is_nil(rule) ->
          {:cont, {:ok, attrs}}

        rule.locked ->
          case value_for_event(key, rule.value, changeset) do
            {:ok, value} ->
              case merge_event_value(changeset, %{}, event_field, value) do
                {:error, _} = error ->
                  {:halt, error}

                values ->
                  conflict? =
                    not mounting? and
                      Enum.any?(values, fn {field, expected} ->
                        Ash.Changeset.changing_attribute?(changeset, field) and
                          Ash.Changeset.get_attribute(changeset, field) != expected
                      end)

                  if conflict?,
                    do: {:halt, {:error, "initiative rule #{key} is locked"}},
                    else: {:cont, {:ok, Map.merge(attrs, values)}}
              end

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        mounting? ->
          case value_for_event(key, rule.value, changeset) do
            {:ok, value} ->
              case merge_event_value(changeset, attrs, event_field, value) do
                {:error, _} = error -> {:halt, error}
                merged -> {:cont, {:ok, merged}}
              end

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        true ->
          {:cont, {:ok, attrs}}
      end
    end)
  end

  defp event_field(:deposit), do: :deposit_enabled
  defp event_field(:age_gate), do: :min_age
  defp event_field(:min_participants), do: :min_participants
  defp event_field(:deadline_rule), do: :registration_deadline

  # KTD3 / R1：Initiative 押金规则（含关闭态）写入前，目标 Event 已开定价则
  # 拒绝并返回稳定业务错误——不静默关闭定价、不改写资金配置。
  # 押金与定价互斥的稳定业务错误（KTD3）：两条拒绝路径（传播前置 / 挂载合并）
  # 同源构造，仅 fields 不同。
  defp pricing_conflict_error(fields) do
    Cgc2046.Errors.BusinessError.exception(
      message: "disable pricing before applying the deposit rule to this event",
      code: "event_payment_mode_exclusive",
      fields: fields
    )
  end

  # #597：押金规则开启时目标场有档位残留（定价关闭但档位非空=R4 合法休眠态）→
  # 拒绝，文案给出补救动作「先清空 price_tiers」。code 与
  # PaymentModeValidation 同源（#241 契约字面量）。
  defp tiers_conflict_error(fields) do
    Cgc2046.Errors.BusinessError.exception(
      message: "clear price tiers before applying the deposit rule to this event",
      code: "event_deposit_price_tiers_conflict",
      fields: fields
    )
  end

  # 押金 × 定价互斥的挂载/锁死合并检查：判据源是 changeset 的**有效**
  # `pricing_enabled`（改值 else 原值），不是累积 attrs——规则 attrs 永远不含
  # `:pricing_enabled`（规则 key 只映射 deposit/min_age/min_participants/
  # registration_deadline），拿 attrs 当判据恒不触发（issue #587 附带缺陷：
  # 原 `Map.get(attrs, :pricing_enabled)` 在 locked 与 mounting 两个分支都是
  # 死码）。
  #
  # 触发条件与 DB CHECK `events_payment_mode_exclusive` 同语义：`enabled and
  # pricing_enabled` 双真。**押金规则关闭态（`enabled: false`）不参与互斥**
  # ——`pricing=true` + `deposit=false` 是合法态（互斥只管双真；
  # `initiative_boundary_test` 「押金关闭态下开定价合法」即此），关闭态规则
  # 写入只是幂等回写，不返回错误。
  #
  # #597 追加档位判据（同样 gate 在 `enabled`）：押金规则开启时 changeset 的
  # 有效 `price_tiers` 非空即拒绝。顺序在 pricing 之后——定价场必然有档位，
  # 先报更根本的互斥（I1 归因优先，与域校验 cond 顺序、与两条不相交 DB CHECK
  # 的归因一致）。判据读 changeset 而非 attrs：规则 attrs 同样不含
  # `:price_tiers`（死码），且挂载路径的残留档位来自 Event 自身。
  defp merge_event_value(changeset, attrs, :deposit_enabled, %{deposit_enabled: enabled} = values) do
    cond do
      enabled and Ash.Changeset.get_attribute(changeset, :pricing_enabled) == true ->
        {:error, pricing_conflict_error(:pricing_enabled)}

      enabled and tiers_present?(changeset) ->
        {:error, tiers_conflict_error(:price_tiers)}

      true ->
        Map.merge(attrs, values)
    end
  end

  defp merge_event_value(_changeset, attrs, field, value), do: Map.put(attrs, field, value)

  # 写后生效值非空即违规（`nil` 是历史畸形值的 fail-closed 侧：一并拒绝）。
  defp tiers_present?(changeset),
    do: Ash.Changeset.get_attribute(changeset, :price_tiers) not in [nil, []]

  defp deposit_enabling?(value),
    do: Map.get(value, "enabled", Map.get(value, :enabled, false)) == true

  defp value_for_event(:deposit, value, _changeset) when is_map(value) do
    enabled = Map.get(value, "enabled", Map.get(value, :enabled, false))
    amount = Map.get(value, "amount_cents", Map.get(value, :amount_cents))

    if is_boolean(enabled) and
         ((not enabled and is_nil(amount)) or (is_integer(amount) and amount > 0)) do
      {:ok, %{deposit_enabled: enabled, deposit_amount_cents: amount}}
    else
      {:error, "invalid deposit rule value"}
    end
  end

  defp value_for_event(:age_gate, value, _changeset) when is_map(value) do
    min_age = Map.get(value, "min_age", Map.get(value, :min_age))

    if is_integer(min_age) and min_age > 0,
      do: {:ok, min_age},
      else: {:error, "invalid age_gate rule value"}
  end

  defp value_for_event(:min_participants, value, _changeset) do
    value = if is_map(value), do: Map.get(value, "count", Map.get(value, :count)), else: value

    if is_integer(value) and value > 0,
      do: {:ok, value},
      else: {:error, "invalid min_participants rule value"}
  end

  defp value_for_event(:deadline_rule, value, changeset) when is_map(value) do
    hours = Map.get(value, "hours_before_start", Map.get(value, :hours_before_start))

    starts_at =
      case changeset do
        %Ash.Changeset{} ->
          Ash.Changeset.get_attribute(changeset, :starts_at)

        %{attributes: attrs} when is_map(attrs) ->
          Map.get(attrs, :starts_at) || Map.get(attrs, "starts_at")

        _ ->
          nil
      end

    cond do
      not (is_integer(hours) and hours >= 0) -> {:error, "invalid deadline_rule rule value"}
      is_nil(starts_at) -> {:ok, nil}
      match?(%DateTime{}, starts_at) -> {:ok, DateTime.add(starts_at, -hours * 3600, :second)}
      true -> {:error, "deadline_rule requires a DateTime starts_at"}
    end
  end

  defp value_for_event(_key, _value, _changeset), do: {:error, "invalid initiative rule value"}
end

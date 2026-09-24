defmodule Cgc2046.Flashback.AdminStats do
  @moduledoc """
  看板（U11/R24/KTD10）：四率 + 分线的聚合查询 + 兑换申请队列（R25）。

  ## 度量契约（KTD10，钉死）

  - **分子** = FlashbackTouch 各事件的 distinct person 数
    （link_opened / revealed / sent_to_wall / intent_submitted）；
  - **分母** = 成功送达人数：`flashback_outreaches.status = 'sent'` 的
    distinct person——硬退信（failed）不计，**退订者剔除**
    （`flashback_people.outreach_unsubscribed_at` 置位即出分母：她们明确
    拒绝继续触达，不再构成漏斗基数）；
  - **分线** = person.participation（attended = 记忆线 / not_selected =
    圆梦线），分子分母同维度切分；
  - 删除档案者不剔除（admin 漏斗是运营真实口径——她们确实经历了触达与
    行为；公开统计层才排除，见 `Public.stats/0`）。

  ## 导出纪律（KTD3）

  导出行 = 本模块聚合结果（率与人数），**结构性无手机/邮箱**——不需要
  字段过滤也不会有 PII。

  ## 兑换申请（R25）

  `redemptions/1` admin 白名单投影（channel_note 含收款账号，admin-only）；
  状态机 `pending → contacted → settled | rejected` 人工处理，非法转移
  fail-closed 拒绝。
  """

  import Ecto.Query

  require Ash.Query

  alias Cgc2046.Flashback.Redemption
  alias Cgc2046.Repo

  @touch_events ~w(link_opened revealed sent_to_wall intent_submitted)
  @lines ~w(memory dream)

  # R25 状态机：人工处理队列的合法转移表（fail-closed：表外转移拒绝）。
  @status_transitions %{
    "pending" => ["contacted", "settled", "rejected"],
    "contacted" => ["settled", "rejected"],
    "settled" => [],
    "rejected" => []
  }

  # ── 四率 + 分线（R24/KTD10） ─────────────────────────────────────────

  @doc """
  四率看板：分母（成功送达）+ 四事件分子，按线（memory/dream）分开统计。

  返回 `%{lines: %{memory => rates, dream => rates}, overall: rates}`，其中
  `rates = %{delivered, link_opened, revealed, sent_to_wall, intent_submitted}`。
  空库各计数为 0（除零守卫：分母 0 时各率为 0）。
  """
  @spec stats() :: {:ok, map()}
  def stats do
    # 分母：sent 的 distinct person（退订者剔除），按线分组。
    delivered_by_line =
      Repo.all(
        from(o in "flashback_outreaches",
          join: p in "flashback_people",
          on: p.id == o.person_id,
          where: o.status == "sent" and is_nil(p.outreach_unsubscribed_at),
          group_by: p.participation,
          select: {p.participation, count(o.person_id, :distinct)}
        )
      )
      |> Map.new()

    # 分子：各事件 distinct person，按线分组。退订者与分母同口径剔除
    # （她已退出触达漏斗——分子含她会造成率 > 100% 的怪相）。
    touches_by_line =
      Repo.all(
        from(t in "flashback_touches",
          join: p in "flashback_people",
          on: p.id == t.person_id,
          where: is_nil(p.outreach_unsubscribed_at),
          group_by: [p.participation, t.event],
          select: {p.participation, t.event, count(t.person_id, :distinct)}
        )
      )
      |> Enum.group_by(
        fn {participation, _event, _count} -> participation end,
        fn {_participation, event, count} -> {event, count} end
      )
      |> Map.new(fn {participation, pairs} -> {participation, Map.new(pairs)} end)

    lines =
      Map.new(@lines, fn line ->
        participation = line_participation(line)

        {line,
         rates_for(
           Map.get(delivered_by_line, participation, 0),
           Map.get(touches_by_line, participation, %{})
         )}
      end)

    total_delivered = Enum.sum(Map.values(delivered_by_line))

    total_touches =
      Enum.reduce(touches_by_line, %{}, fn {_participation, pairs}, acc ->
        Map.merge(acc, pairs, fn _k, a, b -> a + b end)
      end)

    {:ok,
     %{
       memory: Map.fetch!(lines, "memory"),
       dream: Map.fetch!(lines, "dream"),
       overall: rates_for(total_delivered, total_touches)
     }}
  end

  defp line_participation("memory"), do: "attended"
  defp line_participation("dream"), do: "not_selected"

  defp rates_for(delivered, touches) do
    %{
      delivered: delivered,
      link_opened: touch_count(touches, "link_opened"),
      revealed: touch_count(touches, "revealed"),
      sent_to_wall: touch_count(touches, "sent_to_wall"),
      intent_submitted: touch_count(touches, "intent_submitted")
    }
  end

  defp touch_count(touches, event), do: Map.get(touches, event, 0)

  # ── 兑换申请（R25：admin 白名单投影 + 状态流转） ─────────────────────

  @doc """
  兑换申请队列（倒序封顶，默认 50）：白名单投影——channel_note 含收款账号，
  只进 admin 面；person 侧只出掩码姓名（姓** · 城市，同名册脱敏规则）。
  """
  @spec redemptions(pos_integer()) :: {:ok, [map()]}
  def redemptions(limit \\ 50) do
    rows =
      Repo.all(
        from(r in "flashback_redemptions",
          join: p in "flashback_people",
          on: p.id == r.person_id,
          order_by: [desc: r.inserted_at, desc: r.id],
          limit: ^limit,
          select: %{
            id: fragment("?::text", r.id),
            status: r.status,
            channel_note: r.channel_note,
            handled_note: r.handled_note,
            inserted_at: r.inserted_at,
            # 掩码署名（R12 同规则：姓 + **；surname 缺失按 full_name 首字符）
            masked_name:
              fragment(
                "LEFT(COALESCE(?, ?), 1) || '**'",
                p.surname,
                p.full_name
              ),
            city: p.city
          }
        )
      )

    {:ok, Enum.map(rows, &%{&1 | inserted_at: iso8601(&1.inserted_at)})}
  end

  @doc """
  兑换状态流转（人工处理）：合法转移见 `@status_transitions`，非法转移 →
  `{:error, :invalid_transition}`（fail-closed，不静默吞）。
  """
  @spec update_status(String.t(), String.t(), String.t() | nil) ::
          {:ok, map()} | {:error, term()}
  def update_status(redemption_id, next_status, handled_note) do
    with {:ok, redemption} <- fetch(redemption_id),
         :ok <- validate_transition(redemption.status, next_status) do
      redemption
      |> Ash.Changeset.for_update(:admin_update_status, %{
        status: String.to_existing_atom(next_status),
        handled_note: handled_note
      })
      |> Ash.update(authorize?: false)
      |> case do
        {:ok, updated} -> {:ok, %{id: updated.id, status: Atom.to_string(updated.status)}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp fetch(redemption_id) do
    case Ash.get(Redemption, redemption_id, authorize?: false) do
      {:ok, redemption} ->
        {:ok, redemption}

      _ ->
        {:error,
         %{
           code: "flashback_redemption_not_found",
           message: "redemption not found",
           reason: :not_found
         }}
    end
  end

  defp validate_transition(current, next_status) do
    current_key = Atom.to_string(current)

    if next_status in Map.get(@status_transitions, current_key, []) do
      :ok
    else
      {:error,
       %{
         code: "flashback_redemption_invalid_transition",
         message: "cannot move redemption from #{current_key} to #{next_status}",
         reason: :invalid_transition
       }}
    end
  end

  # ── 兑换提交（R25：token/会话面，一人一行幂等） ──────────────────────

  @doc """
  提交兑换申请（当年中奖者自行前来，R7 提醒全场展示）：一人一行——已申请
  再交 = 更新渠道信息（状态不动，人工队列不受重复提交干扰）。
  """
  @spec submit(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def submit(person_id, channel_note) do
    with :ok <- validate_note(channel_note) do
      case Redemption
           |> Ash.Query.for_read(:read)
           |> Ash.Query.filter(person_id == ^person_id)
           |> Ash.read_one(authorize?: false) do
        {:ok, nil} ->
          Redemption
          |> Ash.Changeset.for_create(:create, %{person_id: person_id, channel_note: channel_note})
          |> Ash.create(authorize?: false)
          |> case do
            {:ok, row} -> {:ok, submit_payload(row)}
            {:error, reason} -> {:error, reason}
          end

        {:ok, row} ->
          row
          |> Ash.Changeset.for_update(:update, %{channel_note: channel_note})
          |> Ash.update(authorize?: false)
          |> case do
            {:ok, updated} -> {:ok, submit_payload(updated)}
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp validate_note(note) when is_binary(note) and byte_size(note) >= 5,
    do: :ok

  defp validate_note(_),
    do:
      {:error,
       %{
         code: "flashback_invalid_input",
         message: "channel_note is required (at least 5 characters)",
         reason: :invalid_input
       }}

  defp submit_payload(row) do
    %{status: Atom.to_string(row.status), updated: true}
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp iso8601(%NaiveDateTime{} = ndt),
    do: DateTime.to_iso8601(DateTime.from_naive!(ndt, "Etc/UTC"))

  # 供 MCP 工具与导出复用的口径文档（数字与 stats/0 同源）。
  @doc "四率事件的合法键集（导出/工具未登记键 fail-closed 的依据）。"
  @spec touch_events() :: [String.t()]
  def touch_events, do: @touch_events
end

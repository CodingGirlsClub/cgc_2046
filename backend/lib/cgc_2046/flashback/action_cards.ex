defmodule Cgc2046.Flashback.ActionCards do
  @moduledoc """
  Action 卡域逻辑（U7/R13/KTD5）：四态状态机 + 管理员建卡 + 成场完整编排 +
  done 回贴。

  ## 状态机（线性，非法转移拒绝）

      proposed → forming → scheduled → done

  - `proposed → forming`：首条附议时自动（`Endorsements.endorse/3` 回调）；
  - `forming → scheduled`：管理员确认成场（`schedule/3`，KTD5 完整编排）；
  - `scheduled → done`：管理员回贴活动照片/回顾（`mark_done/3`）。

  ## 成场编排（KTD5 全序列，幂等可重试）

  1. 建 Event（draft，归属运营指定 workspace——缺省 `config :cgc_2046,
     :flashback_default_workspace_slug`（pilot "2046"）；actor=PlatformAdmin，
     服务端 `authorize?: false` + tenant 注入）；
  2. 回填卡 `event_id`（此刻 status 仍 forming——中断重试时卡上有 event_id，
     直接复用存量 Event，不重复建场）；
  3. `:launch`（draft → open；挂载的 Initiative 必须 open，否则
     `initiative_not_open`）；
  4. 卡置 `scheduled`，入队 `ActionFanoutWorker`（args 只带 card_id 锚点，
     unique 全态幂等）。

  测试断言「成场后 Event 出现在 Initiative 公开投影」（fetch_events 只挂
  open + public 场次）由 `action_card_test.exs` 钉住。

  ## 错误码（#241 契约）

  业务 code 在本模块以字面量出现；web 文案在 `web/messages/*.json`。
  """

  require Ash.Query

  alias Cgc2046.Accounts.Policies.PlatformAdmin
  alias Cgc2046.Flashback.{ActionCard, Workers.ActionFanoutWorker}
  alias Cgc2046.Events.Event

  # done 回贴照片（头像先例 workspace_profile.ex 同款口径）。
  @photo_allowed_mime ["image/png", "image/jpeg", "image/webp", "image/gif"]
  @photo_max_data_url_bytes 3_000_000
  @photo_max_http_url_length 2048

  # ── 管理员建卡（KTD5：从 Want/Give 导出人工挑卡，pilot 无自动聚类） ──

  @doc """
  建卡（PlatformAdmin）：标题必填、城市/提议人可选。
  """
  @spec create_card(struct() | nil, map()) :: {:ok, ActionCard.t()} | {:error, term()}
  def create_card(actor, params) do
    with :ok <- ensure_admin(actor) do
      ActionCard
      |> Ash.Changeset.for_create(:create, params, actor: actor)
      |> Ash.create(actor: actor)
    end
  end

  # ── 状态转移 ─────────────────────────────────────────────────────────

  @doc "状态转移表（线性四态；done 为终态）。"
  @spec transitions() :: %{atom() => [atom()]}
  def transitions,
    do: %{proposed: [:forming], forming: [:scheduled], scheduled: [:done], done: []}

  @doc """
  首条附议：`proposed → forming`（`Endorsements.endorse/3` 在创建首行后回调；
  幂等——已 forming 时静默通过）。
  """
  @spec advance_to_forming(ActionCard.t()) :: {:ok, ActionCard.t()} | {:error, term()}
  def advance_to_forming(%ActionCard{} = card) do
    transition(card, :forming)
  end

  # ── 成场编排（KTD5） ─────────────────────────────────────────────────

  @doc """
  管理员确认成场（PlatformAdmin）：`forming → scheduled` + 完整 Event 编排
  （建 draft → 回填 event_id → `:launch` 到 open → 置 scheduled → 入队成场
  通知）。幂等：重试时复用已回填的 event_id，不重复建场。
  """
  @spec schedule(struct() | nil, String.t(), map()) :: {:ok, map()} | {:error, term()}
  def schedule(actor, card_id, params) do
    with :ok <- ensure_admin(actor),
         {:ok, card} <- fetch_card(card_id) do
      # 已 scheduled 的卡重复调用 = 幂等重放：直接返回现有结果（成场只发生
      # 一次；重复确认是重试语义——通知 unique 闸防重发）。
      if card.status == :scheduled and not is_nil(card.event_id) do
        {:ok, card_payload(card, Ash.get!(Event, card.event_id, authorize?: false))}
      else
        do_schedule(card, actor, params)
      end
    end
  end

  defp do_schedule(card, actor, params) do
    with :ok <- ensure_transition(card, :scheduled),
         {:ok, workspace_id} <- resolve_workspace(params),
         {:ok, initiative_id} <- fetch_initiative_id(params),
         {:ok, event} <- ensure_event(card, workspace_id, initiative_id, actor, params),
         :ok <- bind_event(card, event),
         :ok <- launch_event(event, actor),
         {:ok, card} <- reload(card) do
      {:ok, updated} = mark_scheduled(card)

      # 成场通知（KTD5 通道分派在 worker 内：注册者 → Fanout/订阅消息；
      # 未注册附议者 → outreach 邮件/短信）。unique 全态：重复入队被吞。
      {:ok, _} =
        ActionFanoutWorker.new(%{"card_id" => updated.id})
        |> Oban.insert()

      {:ok, card_payload(updated, event)}
    end
  end

  # ── done 回贴（R13「落地有照片回流」） ───────────────────────────────

  @doc """
  管理员回贴（PlatformAdmin）：`scheduled → done`；photo_url 为 data-URL 时按
  头像先例校验（MIME 白名单 + ~3MB 上限），http(s) URL 限长。
  """
  @spec mark_done(struct() | nil, String.t(), map()) :: {:ok, map()} | {:error, term()}
  def mark_done(actor, card_id, params) do
    photo = params[:photo_url] || params["photo_url"]
    recap = params[:recap] || params["recap"]

    with :ok <- ensure_admin(actor),
         {:ok, card} <- fetch_card(card_id),
         :ok <- ensure_transition(card, :done),
         :ok <- validate_photo(photo) do
      card
      |> Ash.Changeset.for_update(:mark_done, %{})
      |> Ash.Changeset.force_change_attribute(:status, :done)
      |> Ash.Changeset.force_change_attribute(:photo_url, photo)
      |> Ash.Changeset.force_change_attribute(:recap, recap)
      |> Ash.update(authorize?: false)
      |> case do
        {:ok, updated} -> {:ok, card_payload(updated, nil)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp reload(%ActionCard{} = card) do
    ActionCard
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^card.id)
    |> Ash.read_one(authorize?: false)
  end

  # ── 内部：状态机 ─────────────────────────────────────────────────────

  defp transition(%ActionCard{} = card, to) do
    if to in Map.get(transitions(), card.status, []) do
      card
      |> Ash.Changeset.for_update(:advance_status, %{})
      |> Ash.Changeset.force_change_attribute(:status, to)
      |> Ash.update(authorize?: false)
    else
      {:ok, card}
    end
  end

  defp ensure_transition(%ActionCard{} = card, to) do
    if to in Map.get(transitions(), card.status, []) do
      :ok
    else
      {:error,
       %{
         code: "flashback_invalid_transition",
         message: "cannot transition from #{card.status} to #{to}",
         reason: :invalid_transition
       }}
    end
  end

  defp ensure_admin(actor) do
    if PlatformAdmin.platform_admin?(actor) do
      :ok
    else
      {:error, %{code: "flashback_forbidden", message: "forbidden", reason: :forbidden}}
    end
  end

  defp fetch_card(card_id) do
    case Ash.get(ActionCard, card_id, authorize?: false) do
      {:ok, card} ->
        {:ok, card}

      _ ->
        {:error,
         %{code: "flashback_card_not_found", message: "card not found", reason: :card_not_found}}
    end
  end

  # ── 内部：成场编排各步 ───────────────────────────────────────────────

  # workspace：入参优先，缺省走 config 的默认 slug（pilot "2046"）。
  defp resolve_workspace(params) do
    case params[:workspace_id] || params["workspace_id"] do
      nil ->
        slug = Application.get_env(:cgc_2046, :flashback_default_workspace_slug, "2046")

        case Cgc2046.Accounts.Workspace
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(slug == ^slug)
             |> Ash.read_one(authorize?: false) do
          {:ok, nil} ->
            {:error,
             %{
               code: "flashback_workspace_not_found",
               message: "default workspace not found",
               reason: :workspace_not_found
             }}

          {:ok, workspace} ->
            {:ok, workspace.id}

          {:error, reason} ->
            {:error, reason}
        end

      workspace_id ->
        {:ok, workspace_id}
    end
  end

  # Initiative：成场必挂（1024 立项）；slug 或 id 任一。
  defp fetch_initiative_id(params) do
    slug = params[:initiative_slug] || params["initiative_slug"]
    id = params[:initiative_id] || params["initiative_id"]

    cond do
      is_binary(id) and id != "" ->
        {:ok, id}

      is_binary(slug) and slug != "" ->
        case Cgc2046.Initiatives.Initiative
             |> Ash.Query.for_read(:read)
             |> Ash.Query.filter(slug == ^slug)
             |> Ash.read_one(authorize?: false) do
          {:ok, nil} ->
            {:error,
             %{
               code: "flashback_initiative_not_found",
               message: "initiative not found",
               reason: :initiative_not_found
             }}

          {:ok, initiative} ->
            {:ok, initiative.id}

          {:error, reason} ->
            {:error, reason}
        end

      true ->
        {:error,
         %{
           code: "flashback_initiative_required",
           message: "initiative_slug or initiative_id is required",
           reason: :initiative_required
         }}
    end
  end

  # 幂等建场：卡上已有 event_id（上次编排中断）→ 复用存量 Event。
  defp ensure_event(
         %ActionCard{event_id: event_id},
         _workspace_id,
         _initiative_id,
         _actor,
         _params
       )
       when not is_nil(event_id) do
    case Ash.get(Event, event_id, authorize?: false) do
      {:ok, event} ->
        {:ok, event}

      _ ->
        {:error,
         %{
           code: "flashback_event_missing",
           message: "bound event missing",
           reason: :event_missing
         }}
    end
  end

  defp ensure_event(%ActionCard{} = card, workspace_id, initiative_id, actor, params) do
    # venue 结构合法（country/province/city/district）才传；nil 留待运营编辑
    # （空 map 会被 Event 的 venue 校验拒绝）。title 缺省用卡标题。
    base = %{
      title: params[:title] || params["title"] || card.title,
      starts_at: params[:starts_at] || params["starts_at"],
      ends_at: params[:ends_at] || params["ends_at"],
      initiative_id: initiative_id,
      visibility: :public,
      workspace_id: workspace_id
    }

    attrs =
      case params[:venue] || params["venue"] do
        nil -> base
        venue -> Map.put(base, :venue, venue)
      end

    Event
    |> Ash.Changeset.for_create(:create, attrs, actor: actor, tenant: workspace_id)
    |> Ash.create(authorize?: false, tenant: workspace_id)
  end

  # 回填 event_id（status 仍 forming）：launch 前落锚点，中断可续。
  defp bind_event(%ActionCard{} = card, event) do
    if card.event_id == event.id do
      :ok
    else
      card
      |> Ash.Changeset.for_update(:schedule, %{})
      |> Ash.Changeset.force_change_attribute(:event_id, event.id)
      |> Ash.update(authorize?: false)
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # launch：draft → open（挂载 Initiative 必须 open：initiative_not_open）。
  # 已 open（重试路径）幂等通过。
  defp launch_event(%Event{status: :open}, _actor), do: :ok

  defp launch_event(%Event{} = event, actor) do
    event
    |> Ash.Changeset.for_update(:launch, %{}, actor: actor)
    |> Ash.update(authorize?: false, tenant: event.workspace_id)
    |> case do
      {:ok, _launched} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_scheduled(%ActionCard{} = card) do
    card
    |> Ash.Changeset.for_update(:schedule, %{})
    |> Ash.Changeset.force_change_attribute(:status, :scheduled)
    |> Ash.update(authorize?: false)
  end

  # ── 内部：照片校验（头像先例同款） ──────────────────────────────────

  defp validate_photo(nil), do: :ok

  defp validate_photo("data:" <> rest) do
    case String.split(rest, ";", parts: 2) do
      [mime, "base64," <> _] ->
        cond do
          mime not in @photo_allowed_mime ->
            {:error,
             %{
               code: "flashback_photo_invalid",
               message: "photo data URL MIME must be one of png/jpeg/webp/gif",
               reason: :photo_invalid_mime
             }}

          byte_size("data:" <> rest) > @photo_max_data_url_bytes ->
            {:error,
             %{
               code: "flashback_photo_too_large",
               message: "photo data URL too large (max ~2.2MB image)",
               reason: :photo_too_large
             }}

          true ->
            :ok
        end

      _ ->
        {:error,
         %{
           code: "flashback_photo_invalid",
           message: "photo data URL must be base64-encoded image",
           reason: :photo_invalid
         }}
    end
  end

  defp validate_photo(url) when is_binary(url) do
    if (String.starts_with?(url, "http://") or String.starts_with?(url, "https://")) and
         byte_size(url) <= @photo_max_http_url_length do
      :ok
    else
      {:error,
       %{
         code: "flashback_photo_invalid",
         message: "photoUrl must be a data URL or http(s) URL",
         reason: :photo_invalid
       }}
    end
  end

  # ── 内部：响应投影 ───────────────────────────────────────────────────

  defp card_payload(card, event) do
    %{
      id: card.id,
      title: card.title,
      city: card.city,
      status: Atom.to_string(card.status),
      event_id: card.event_id,
      event_slug: event && event.slug,
      photo_url: card.photo_url,
      recap: card.recap
    }
  end
end

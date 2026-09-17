defmodule Cgc2046.Flashback.Workers.OutreachWorker do
  @moduledoc """
  闪念间外发 worker（U8/KTD6）：**token 铸造在 worker 内完成**——生成 → 渲染 →
  发送 → 只落 `token_hash`（KTD2 明文不落任何持久化载体；Oban args 只带
  person_id / channel / batch / template，无 PII 无明文 token）。

  ## 重试与断点续发

  - 发送失败 → outreach 行 `mark_failed` + `{:error, _}` 交 Oban 重试；重试对
    `failed` 行照常重发（只有 `sent` 跳过）——批中断在任意点，重跑 dispatch 对
    已 sent 者零动作（unique_send 双闸），未完成者由此 worker 续发；
  - person 已删除 / 已退订 / 卡已撤下 → 静默跳过（`:ok`，不重试：状态不会自愈）。

  ## 模板分派

  `reconnect`（唤醒首封）/ `action_scheduled`（U7 成场通知；args 带 `card_id`
  锚点，worker 内 stale 重查取最新 title 与 event slug——不在 args 里快照业务
  字段）。
  """

  use Oban.Worker,
    queue: :outreach,
    max_attempts: 5,
    unique: [period: 604_800, fields: [:worker, :args], states: :all]

  require Ash.Query
  require Logger

  import Ecto.Query

  alias Cgc2046.Accounts.TokenCredential

  alias Cgc2046.Flashback.{
    ActionCard,
    Outreach,
    Outreach.Dispatch,
    Outreach.Emails,
    Person,
    Token
  }

  alias Cgc2046.Mailer
  alias Cgc2046.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    person_id = args["person_id"]
    channel = String.to_existing_atom(args["channel"])
    batch = args["batch"]
    template = args["template"]

    with {:ok, person} <- fetch_person(person_id, channel),
         :ok <- ensure_not_unsubscribed(person_id),
         {:ok, row} <- ensure_outreach_row(person_id, channel, template, batch),
         :ok <- ensure_not_sent(row),
         {:ok, plaintext} <- mint_token(person_id),
         {:ok, delivered} <- render_and_deliver(template, channel, person, plaintext, args) do
      mark_sent(row)
      {:ok, delivered}
    else
      {:skip, _detail} ->
        :ok

      {:error, reason} = error ->
        mark_failed(person_id, channel, template, batch, reason)
        error
    end
  end

  # ── 发送前的状态闸 ───────────────────────────────────────────────────

  defp fetch_person(person_id, channel) do
    Person
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^person_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      # 档案已删除（U10 级联匿名化后通道字段为空）→ 不再触达，静默终态。
      {:ok, %Person{} = person} ->
        if reachable?(person, channel) do
          {:ok, person}
        else
          {:skip, "person_not_reachable"}
        end

      {:ok, nil} ->
        {:skip, "person_missing"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # 只判「档案有没有该通道的联系方式」：模板/凭证配置检查留给发送步的
  # fail-closed（配置缺失是可修复事故 → 显式 error 让重试与运维可见；无联系
  # 方式是终态事实 → skip）。
  defp reachable?(person, :email), do: present?(person.email)
  defp reachable?(person, :sms), do: present?(person.phone)

  defp ensure_not_unsubscribed(person_id) do
    if Dispatch.unsubscribed?(person_id) do
      {:skip, "unsubscribed"}
    else
      :ok
    end
  end

  defp ensure_outreach_row(person_id, channel, template, batch) do
    Outreach
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(person_id == ^person_id and channel == ^channel and batch == ^batch)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} ->
        Outreach
        |> Ash.Changeset.for_create(:create, %{
          person_id: person_id,
          channel: channel,
          template: template,
          batch: batch
        })
        |> Ash.create(authorize?: false)

      {:ok, row} ->
        {:ok, row}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_not_sent(%Outreach{status: :sent}), do: {:skip, "already_sent"}
  defp ensure_not_sent(%Outreach{}), do: :ok

  # ── token 铸造（KTD2：明文只在本进程内存存在过） ────────────────────

  defp mint_token(person_id) do
    plaintext = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    with {:ok, hash} <- TokenCredential.hash(plaintext),
         {:ok, _token} <-
           Token
           |> Ash.Changeset.for_create(:create, %{person_id: person_id, token_hash: hash})
           |> Ash.create(authorize?: false) do
      {:ok, plaintext}
    end
  end

  # ── 渲染与发送（email / sms 双通道） ─────────────────────────────────

  defp render_and_deliver("reconnect", :email, person, plaintext, _args) do
    person.email
    |> Emails.reconnect(display_name(person), enter_url(plaintext), unsub_url(person.id))
    |> Mailer.deliver()
    |> case do
      {:ok, _} -> {:ok, :email}
      {:error, reason} -> {:error, reason}
    end
  end

  defp render_and_deliver("action_scheduled", :email, person, _plaintext, args) do
    with {:ok, %{title: title, url: url}} <- scheduled_card(args) do
      person.email
      |> Emails.action_scheduled(display_name(person), title, url, unsub_url(person.id))
      |> Mailer.deliver()
      |> case do
        {:ok, _} -> {:ok, :email}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # 短信模板附退订短链（KTD6）：vars = url + unsub 两个模板变量（SendCloud
  # 后台申请触达模板时按此变量名定制）；模板未配置时入队面已抑制 sms 通道，
  # 此处再 fail-closed 一次（配置竞态）。
  defp render_and_deliver(template, :sms, person, plaintext, args) do
    if Dispatch.sms_configured?() do
      with {:ok, url} <- sms_link(template, plaintext, args) do
        Cgc2046.Integrations.SendCloud.Sms.send_template_sms(
          person.phone,
          Dispatch.sms_template_id(),
          %{"url" => url, "unsub" => unsub_url(person.id)},
          "flashback-outreach-#{person.id}"
        )
        |> case do
          :ok -> {:ok, :sms}
          {:error, reason} -> {:error, reason}
        end
      end
    else
      {:error, :sms_not_configured}
    end
  end

  defp render_and_deliver(template, _channel, _person, _plaintext, _args) do
    {:skip, "no_renderer_for_#{template}"}
  end

  # action_scheduled 的活动直达链接（stale 重查：args 只带 card_id 锚点）。
  defp scheduled_card(%{"card_id" => card_id}) do
    ActionCard
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^card_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %ActionCard{status: :scheduled, event_id: event_id} = card}
      when not is_nil(event_id) ->
        case event_slug(event_id) do
          nil -> {:skip, "event_missing"}
          slug -> {:ok, %{title: card.title, url: event_url(slug)}}
        end

      # 卡被撤下/未成场/不存在（含 nil）：通知已无意义，静默跳过（重查教训 L5）。
      {:ok, _card} ->
        {:skip, "card_not_scheduled"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp scheduled_card(_args), do: {:skip, "card_id_missing"}

  defp sms_link("reconnect", plaintext, _args), do: {:ok, enter_url(plaintext)}

  defp sms_link("action_scheduled", _plaintext, args) do
    case scheduled_card(args) do
      {:ok, %{url: url}} -> {:ok, url}
      other -> other
    end
  end

  # events 是多租户表，跨租户取 slug 用裸查询（Ash 全局读要 tenant；此处只读
  # 公开投影同款字段，无策略面）。
  defp event_slug(event_id) do
    from(e in "events",
      where: e.id == type(^event_id, Ecto.UUID) and e.status == "open",
      select: e.slug
    )
    |> Repo.one()
  end

  # ── 状态回写 ─────────────────────────────────────────────────────────

  defp mark_sent(row) do
    row
    |> Ash.Changeset.for_update(:mark_sent, %{})
    |> Ash.update(authorize?: false)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("[flashback] mark_sent failed: #{inspect(reason)}")
    end
  end

  defp mark_failed(person_id, channel, template, batch, reason) do
    result =
      Outreach
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(person_id == ^person_id and channel == ^channel and batch == ^batch)
      |> Ash.read_one(authorize?: false)
      |> case do
        {:ok, nil} ->
          Outreach
          |> Ash.Changeset.for_create(:create, %{
            person_id: person_id,
            channel: channel,
            template: template,
            batch: batch
          })
          |> Ash.Changeset.force_change_attribute(:status, :failed)
          |> Ash.Changeset.force_change_attribute(:detail, detail_text(reason))
          |> Ash.create(authorize?: false)

        {:ok, row} ->
          row
          |> Ash.Changeset.for_update(:mark_failed, %{detail: detail_text(reason)})
          |> Ash.update(authorize?: false)

        other ->
          other
      end

    if match?({:error, _}, result) do
      Logger.warning("[flashback] mark_failed write error: #{inspect(result)}")
    end
  end

  # 失败原因只留类别摘要（Errors.ValueSummary 红线：不回显内容）。
  defp detail_text(reason), do: reason |> inspect() |> String.slice(0, 200)

  # ── 链接构造 ─────────────────────────────────────────────────────────

  defp enter_url(plaintext) do
    "#{base_url()}/zh-CN/flashback/enter?token=#{plaintext}"
  end

  defp event_url(slug) do
    "#{base_url()}/zh-CN/events/#{slug}"
  end

  defp unsub_url(person_id) do
    "#{base_url()}/api/flashback/unsubscribe?t=#{Dispatch.unsubscribe_token(person_id)}"
  end

  defp base_url do
    Application.get_env(:cgc_2046, :web_base_url, "http://localhost:3000")
    |> to_string()
    |> String.trim_trailing("/")
  end

  defp display_name(%Person{surname: surname, full_name: full_name}) do
    case surname do
      s when is_binary(s) and s != "" -> "#{s}同学"
      _ -> full_name
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end

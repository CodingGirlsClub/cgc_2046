defmodule Cgc2046.Flashback.Outreach.Dispatch do
  @moduledoc """
  批量触达的收件人解析与入队（U8/KTD6，照 `Notifications.Fanout` 形状：
  解析与入队分离，worker 只管发送）。

  ## 幂等与断点续发（双闸）

  - Oban unique `[fields: [:worker, :args], states: :all]`（7 天窗）挡重复 job；
  - `flashback_outreaches.unique_send`（person + channel + batch）DB 级挡重跑
    批次的重复行——重跑 `enqueue_for_archive/2` 对已入队者零新增。

  ## 速率（可配）

  入队时按 `config :cgc_2046, :flashback_outreach, per_minute:` 错峰
  `scheduled_at`（第 i 件 = now + i × 60_000/per_minute ms）——发送速率收敛到
  可配常量，队列并发只防局部尖峰。

  ## 退订（R30，KTD6）

  - 抑制按**人**双通道：该人任一 outreach 行 `unsubscribed_at` 非空即不再入队
    （email 与 sms 通道一并抑制）；
  - 退订 token = `Phoenix.Token`（HMAC 签名，90 天窗）——邮件页脚链接与短信
    短链共用同一端点（`/api/flashback/unsubscribe`），一次性语义由置位幂等承载
    （重复点击显示已退订）。

  ## 错误码（#241 契约）

  业务 code 在本模块以字面量出现，经 `mix cgc2046.gen_error_codes_contract` 进
  契约；web 文案在 `web/messages/*.json` errors namespace。
  """

  require Ash.Query

  alias Cgc2046.Flashback.{EventArchive, Outreach, Person, Workers.OutreachWorker}

  # 触达模板白名单（邮件渲染子句与短信模板各自对应；新模板须同步
  # Outreach.Emails 与 OutreachWorker 的渲染分派）。
  @templates ~w(reconnect)

  # 退订 token 的签名盐与有效期（首封触达后 90 天内可退；过期再点走找回入口）。
  @unsub_salt "flashback-unsubscribe"
  @unsub_max_age 90 * 24 * 3600

  # ── 入队面（R23：按场次批量；U7：按附议者定向） ─────────────────────

  @doc """
  按场次批量入队（R23）：该场次全部**可触达**校友（email 或 phone 非空、未退订）
  逐人入 outreach 队列，批次号 `archive-<key>`。返回入队/跳过计数。
  """
  @spec enqueue_for_archive(String.t(), String.t()) ::
          {:ok, %{queued: non_neg_integer(), skipped: non_neg_integer()}} | {:error, term()}
  def enqueue_for_archive(archive_key, template) do
    with {:ok, archive} <- fetch_archive(archive_key),
         :ok <- validate_template(template) do
      {person_ids, filtered_out} = reachable_person_ids(archive.id)

      {queued, skipped} = enqueue_persons(person_ids, template, "archive-" <> archive.key)

      # skipped 三路合计：退订/无通道（解析层）+ 本批次已入队（幂等层）——运营面
      # 从计数即可读出「多少人有通道、多少人被抑制、多少人重复」。
      {:ok, %{queued: queued, skipped: skipped + filtered_out}}
    end
  end

  @doc """
  定向入队（U7 成场通知）：给定 person 列表入队，批次号由调用方给定
  （成场用 `card-<card_id>`）。退订者在入队面即被抑制。
  """
  @spec enqueue_persons([String.t()], String.t(), String.t()) ::
          {non_neg_integer(), non_neg_integer()}
  def enqueue_persons(person_ids, template, batch) when is_list(person_ids) do
    suppressed = suppressed_person_ids()
    persons = persons_by_id(person_ids)
    now = DateTime.utc_now()

    {entries, skipped} =
      Enum.uniq(person_ids)
      |> Enum.reduce({[], 0}, fn person_id, {acc, skipped} ->
        cond do
          MapSet.member?(suppressed, person_id) ->
            {acc, skipped + 1}

          true ->
            case persons |> Map.get(person_id) |> channel_for() do
              nil ->
                {acc, skipped + 1}

              channel ->
                case insert_outreach_row(person_id, channel, template, batch) do
                  {:ok, _row} ->
                    {[{person_id, channel} | acc], skipped}

                  {:error, _unique} ->
                    # unique_send 冲突 = 该人该通道该批次已入队（断点续发重跑）。
                    {acc, skipped + 1}
                end
            end
        end
      end)

    jobs =
      entries
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.map(fn {{person_id, channel}, index} ->
        OutreachWorker.new(
          %{
            "person_id" => person_id,
            "channel" => to_string(channel),
            "batch" => batch,
            "template" => template
          },
          scheduled_at: stagger(now, index)
        )
      end)

    if jobs == [] do
      {0, skipped}
    else
      Oban.insert_all(jobs)
      {length(jobs), skipped}
    end
  end

  @doc "入队模板白名单。"
  @spec templates() :: [String.t()]
  def templates, do: @templates

  # ── 退订（R30：真源 = flashback_people.outreach_unsubscribed_at） ────

  @doc "该人是否已退订（置位即 email 与 sms 双通道全抑制）。"
  @spec unsubscribed?(String.t()) :: boolean()
  def unsubscribed?(person_id) do
    Person
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^person_id and not is_nil(outreach_unsubscribed_at))
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> false
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  退订（幂等）：置 person 的 `outreach_unsubscribed_at`——此后任何批次、任何
  通道（email/sms）不再入队（KTD6 按人抑制双通道）。真源在 person 行而非
  outreach 行：首封邮件点击退订时尚无发送行，行内标记会漏置位。
  """
  @spec unsubscribe_person(String.t()) :: :ok
  def unsubscribe_person(person_id) do
    Person
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^person_id)
    |> Ash.read_one!(authorize?: false)
    |> case do
      nil ->
        :ok

      person ->
        _ =
          person
          |> Ash.Changeset.for_update(:update, %{})
          |> Ash.Changeset.force_change_attribute(
            :outreach_unsubscribed_at,
            DateTime.utc_now()
          )
          |> Ash.update(authorize?: false)

        :ok
    end
  end

  @doc "铸造退订 token（邮件页脚与短信短链共用；HMAC 签名，90 天窗）。"
  @spec unsubscribe_token(String.t()) :: String.t()
  def unsubscribe_token(person_id) do
    Phoenix.Token.sign(Cgc2046Web.Endpoint, @unsub_salt, person_id)
  end

  @doc """
  验证退订 token → person_id；无效/过期 → `{:error, :invalid_token}`
  （端点侧统一渲染无效页，不区分原因）。
  """
  @spec verify_unsubscribe_token(String.t()) :: {:ok, String.t()} | {:error, :invalid_token}
  def verify_unsubscribe_token(token) when is_binary(token) and token != "" do
    case Phoenix.Token.verify(Cgc2046Web.Endpoint, @unsub_salt, token, max_age: @unsub_max_age) do
      {:ok, person_id} when is_binary(person_id) -> {:ok, person_id}
      _ -> {:error, :invalid_token}
    end
  end

  def verify_unsubscribe_token(_), do: {:error, :invalid_token}

  # ── 匿名化（R30「从第一封邮件起生效」；U10 删除级联消费） ────────────

  @doc """
  档案个人字段匿名化：清空 phone/email/city/occupation_then/gender 并把姓名替换
  为占位——outreach 行经 person_id 回查 Person 的路径自此拿不到任何 PII
  （外发 worker 与投影同一条边界）；行本身保留（发送状态聚合统计，U11 分母）。
  """
  @spec anonymize_person(String.t()) :: :ok | {:error, term()}
  def anonymize_person(person_id) do
    Person
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^person_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} ->
        :ok

      {:ok, person} ->
        person
        |> Ash.Changeset.for_update(:update, %{})
        |> Ash.Changeset.force_change_attribute(:full_name, "已删除档案")
        |> Ash.Changeset.force_change_attribute(:surname, nil)
        |> Ash.Changeset.force_change_attribute(:phone, nil)
        |> Ash.Changeset.force_change_attribute(:email, nil)
        |> Ash.Changeset.force_change_attribute(:city, nil)
        |> Ash.Changeset.force_change_attribute(:occupation_then, nil)
        |> Ash.Changeset.force_change_attribute(:gender, nil)
        |> Ash.update(authorize?: false)
        |> case do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── 短信通道门（fail-closed，KTD6） ─────────────────────────────────

  @doc """
  唤醒短信通道是否就绪：SendCloud 验证码凭证 + 触达模板 ID 均已配置。
  模板在 SendCloud 后台申请前恒 false——outreach 短信腿不外呼（邮件腿不受影响）。
  """
  @spec sms_configured?() :: boolean()
  def sms_configured? do
    sms_configured?(sms_template_id())
  end

  defp sms_configured?(template_id) when is_binary(template_id) and template_id != "" do
    Cgc2046.Integrations.SendCloud.Sms.configured?()
  end

  defp sms_configured?(_), do: false

  @doc "唤醒短信模板 ID（未配置返回 nil；worker 渲染短信前判 configured?）。"
  @spec sms_template_id() :: String.t() | nil
  def sms_template_id do
    case Application.get_env(:cgc_2046, :flashback_sms, []) |> Keyword.get(:template_id) do
      template_id when is_binary(template_id) and template_id != "" -> template_id
      _ -> nil
    end
  end

  # ── 内部 ─────────────────────────────────────────────────────────────

  defp fetch_archive(archive_key) do
    EventArchive
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(key == ^archive_key)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} ->
        {:error,
         %{
           code: "flashback_archive_not_found",
           message: "archive not found",
           reason: :archive_not_found
         }}

      {:ok, archive} ->
        {:ok, archive}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_template(template) when template in @templates, do: :ok

  defp validate_template(_),
    do: {:error, invalid_input_error("template must be one of #{Enum.join(@templates, "|")}")}

  defp invalid_input_error(message),
    do: %{code: "flashback_invalid_input", message: message, reason: :invalid_input}

  # 可触达 = 有可用通道（email 优先，phone 需短信模板就绪）且未退订。
  # 返回 {ids, filtered_out}：解析层被抑制/无通道的人数计入 skipped（运营面
  # 从 enqueue 计数即可读出触达面收窄了多少）。
  defp reachable_person_ids(archive_id) do
    suppressed = suppressed_person_ids()

    {ids, filtered_out} =
      Person
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(archive_event_id == ^archive_id)
      |> Ash.read!(authorize?: false, page: false)
      |> Enum.reduce({[], 0}, fn person, {ids, out} ->
        if MapSet.member?(suppressed, person.id) or channel_for(person) == nil do
          {ids, out + 1}
        else
          {[person.id | ids], out}
        end
      end)

    {Enum.reverse(ids), filtered_out}
  end

  defp persons_by_id(person_ids) do
    Person
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id in ^Enum.uniq(person_ids))
    |> Ash.read!(authorize?: false, page: false)
    |> Map.new(&{&1.id, &1})
  end

  defp channel_for(person) do
    cond do
      present?(person.email) -> :email
      present?(person.phone) and sms_configured?() -> :sms
      true -> nil
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""

  defp present?(_), do: false

  defp suppressed_person_ids do
    Person
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(not is_nil(outreach_unsubscribed_at))
    |> Ash.read!(authorize?: false, page: false)
    |> MapSet.new(& &1.id)
  end

  defp insert_outreach_row(person_id, channel, template, batch) do
    Outreach
    |> Ash.Changeset.for_create(:create, %{
      person_id: person_id,
      channel: channel,
      template: template,
      batch: batch
    })
    |> Ash.create(authorize?: false)
  end

  # 第 i 件（0-based）= now + i × (60_000 / per_minute) ms——发送速率上限收敛到
  # 可配常量（config :cgc_2046, :flashback_outreach, per_minute:）。
  defp stagger(now, index) do
    per_minute =
      Application.get_env(:cgc_2046, :flashback_outreach, [])
      |> Keyword.get(:per_minute, 120)
      |> max(1)

    DateTime.add(now, index * div(60_000, per_minute), :millisecond)
  end
end

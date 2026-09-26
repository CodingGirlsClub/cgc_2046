defmodule Cgc2046.Flashback.Outreach.Dispatch do
  @moduledoc """
  批量触达的收件人解析与入队（U8/KTD6，照 `Notifications.Fanout` 形状：
  解析与入队分离，worker 只管发送）。

  ## 幂等与断点续发（双闸）

  - Oban unique `[fields: [:worker, :args], states: :all]`（7 天窗）挡重复 job；
  - `flashback_outreaches.unique_send`（person + channel + batch）DB 级挡重跑
    批次的重复行——重跑 `enqueue_for_archive/2` 对已入队者零新增。

  ## campaign 去重（联系方式级，批次边界 = batch 字符串全等）

  同一 batch 内所有「成功触达」行（状态 `:queued`/`:sent`——即已排定或已发；
  `:failed` 硬退信不算触达、所属人退订的行不算触达）的联系方式构成 campaign
  触达面：候选人的 email（trim+downcase）或 phone（归一至 11 位大陆手机
  口径）命中他人的触达面 → 跳过并计 `deduped_within_campaign`（不计 skipped）。
  候选人本人的历史行不算命中（幂等重跑仍走 unique_send → skipped 语义）。

  批次边界：跨 archive 全量发显式共用同一 campaign batch（如
  `campaign-<date>-all`，38 个 archive 全量发、一个真人只收一封）；默认
  `archive-<key>` 批次互相独立不感知；`resend-*` 单人补救批次恒独立。

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
  require Logger

  alias Cgc2046.Accounts.AdminActionLog
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
  逐人入 outreach 队列，批次号 `archive-<key>`（`batch:` 覆盖，campaign 去重
  见 moduledoc）。返回入队/跳过/campaign 去重计数。

  通道选择（R11）：`:all` = email 优先、phone 需短信就绪（现行为）；`:email` =
  仅 email 可达者走 email；`:sms` = 仅 phone 可达者走 sms（含也有 email 者）。
  """
  @spec enqueue_for_archive(String.t(), String.t(), atom(), keyword()) ::
          {:ok,
           %{
             queued: non_neg_integer(),
             skipped: non_neg_integer(),
             deduped_within_campaign: non_neg_integer()
           }}
          | {:error, term()}
  def enqueue_for_archive(archive_key, template, channel \\ :all, opts \\ []) do
    with {:ok, archive} <- fetch_archive(archive_key),
         :ok <- validate_template(template),
         :ok <- validate_channel(channel) do
      {person_ids, filtered_out} = reachable_person_ids(archive.id, channel)

      batch = Keyword.get(opts, :batch) || "archive-" <> archive.key

      {queued, skipped, deduped} = enqueue_persons(person_ids, template, batch, channel)

      # 治理留痕单源（R1）：MCP 确认流工具与 /admin/flashback GraphQL 面两
      # 入口共用；审计失败不阻塞已入队的发送。
      log_dispatch_action(
        :flashback_outreach_send,
        Keyword.get(opts, :actor),
        :flashback_event_archive,
        archive.id,
        %{
          archive_key: archive_key,
          template: template,
          channel: to_string(channel),
          batch: batch,
          queued: queued,
          skipped: skipped + filtered_out
        }
      )

      # skipped 三路合计：退订/无通道（解析层）+ 本批次已入队（幂等层）——运营面
      # 从计数即可读出「多少人有通道、多少人被抑制、多少人重复」。
      {:ok, %{queued: queued, skipped: skipped + filtered_out, deduped_within_campaign: deduped}}
    end
  end

  @doc """
  定向入队（U7 成场通知）：给定 person 列表入队，批次号由调用方给定
  （成场用 `card-<card_id>`）。退订者在入队面即被抑制。通道选择同
  `enqueue_for_archive/4`（R11）。返回 `{queued, skipped, deduped}`——
  同 batch 内联系方式命中他人已有成功触达者计 deduped（不计 skipped）。
  """
  @spec enqueue_persons([String.t()], String.t(), String.t(), atom()) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def enqueue_persons(person_ids, template, batch, channel \\ :all) when is_list(person_ids) do
    suppressed = suppressed_person_ids()
    persons = persons_by_id(person_ids)
    now = DateTime.utc_now()

    {entries, skipped, deduped, _contacts} =
      Enum.uniq(person_ids)
      |> Enum.reduce({[], 0, 0, campaign_contacts(batch)}, fn person_id,
                                                              {acc, skipped, deduped, contacts} ->
        person = Map.get(persons, person_id)

        cond do
          MapSet.member?(suppressed, person_id) ->
            {acc, skipped + 1, deduped, contacts}

          contact_hit?(contacts, person) ->
            # campaign 去重：同联系方式已有他人成功触达（moduledoc 批次边界）。
            {acc, skipped, deduped + 1, contacts}

          true ->
            case channel_for(person, channel) do
              nil ->
                {acc, skipped + 1, deduped, contacts}

              channel ->
                case insert_outreach_row(person_id, channel, template, batch) do
                  {:ok, _row} ->
                    # 本调用内新入队者即刻进入触达面——同批后段同联系方式者去重。
                    {[{person_id, channel} | acc], skipped, deduped,
                     register_contact(contacts, person)}

                  {:error, _unique} ->
                    # unique_send 冲突 = 该人该通道该批次已入队（断点续发重跑）。
                    {acc, skipped + 1, deduped, contacts}
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
      {0, skipped, deduped}
    else
      Oban.insert_all(jobs)
      {length(jobs), skipped, deduped}
    end
  end

  @doc "入队模板白名单。"
  @spec templates() :: [String.t()]
  def templates, do: @templates

  @doc """
  单人重发（R2/R5 运营补救路径）：对未认领、未退订、未删除且可达的校友
  重新入队，批次号 `resend-<uuid 短码>`（独立于 archive 批次，幂等语义同
  unique_send）。不可重发者返回带原因的业务错误，零新增行；不做频控
  （KD8——每次重发都经确认流把关）。通道选择同 `enqueue_for_archive/3`。
  """
  @spec resend_for_person(String.t(), String.t(), atom(), term()) ::
          {:ok,
           %{
             queued: non_neg_integer(),
             skipped: non_neg_integer(),
             deduped_within_campaign: non_neg_integer(),
             batch: String.t()
           }}
          | {:error, term()}
  def resend_for_person(person_id, template, channel \\ :all, actor \\ nil) do
    with {:ok, _person} <- validate_resend_for_person(person_id),
         :ok <- validate_template(template),
         :ok <- validate_channel(channel) do
      batch = "resend-" <> binary_part(Ecto.UUID.generate(), 0, 8)
      {queued, skipped, deduped} = enqueue_persons([person_id], template, batch, channel)

      # 治理留痕单源（R2）：两入口共用，形状同上。
      log_dispatch_action(:flashback_outreach_resend, actor, :flashback_person, person_id, %{
        template: template,
        channel: to_string(channel),
        batch: batch,
        queued: queued,
        skipped: skipped
      })

      {:ok, %{queued: queued, skipped: skipped, deduped_within_campaign: deduped, batch: batch}}
    end
  end

  @doc """
  场次名册的通道分布（R4 确认摘要 / 页面预览共用口径，KTD2 单源）：
  三档计数 + 退订/不可达剔除。sms 腿是否就绪由调用方取 `sms_configured?/0`
  标示（sms_only 计数恒含「有 phone 但短信未就绪」者，仅影响可达性不影响计数）。
  """
  @spec archive_channel_breakdown(String.t()) ::
          {:ok,
           %{
             email_only: non_neg_integer(),
             sms_only: non_neg_integer(),
             both: non_neg_integer(),
             unsubscribed: non_neg_integer(),
             unreachable: non_neg_integer()
           }}
          | {:error, term()}
  def archive_channel_breakdown(archive_id) do
    suppressed = suppressed_person_ids()

    counts =
      Person
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(archive_event_id == ^archive_id)
      |> Ash.read!(authorize?: false, page: false)
      |> Enum.reduce(%{email_only: 0, sms_only: 0, both: 0, unsubscribed: 0, unreachable: 0}, fn
        person, acc ->
          cond do
            MapSet.member?(suppressed, person.id) ->
              Map.update!(acc, :unsubscribed, &(&1 + 1))

            present?(person.email) and present?(person.phone) ->
              Map.update!(acc, :both, &(&1 + 1))

            present?(person.email) ->
              Map.update!(acc, :email_only, &(&1 + 1))

            present?(person.phone) ->
              Map.update!(acc, :sms_only, &(&1 + 1))

            true ->
              Map.update!(acc, :unreachable, &(&1 + 1))
          end
      end)

    {:ok, counts}
  end

  @doc """
  campaign 去重预判（预览与入队同源，KTD2）：该场次按所选通道档的可达人中，
  联系方式命中 campaign 批次已有成功触达（他人行）的人数；`batch` 为 nil
  恒 0（默认 archive 批次跨场次互不感知，无预判意义）。
  """
  @spec campaign_dedup_count(String.t(), atom(), String.t() | nil) :: non_neg_integer()
  def campaign_dedup_count(_archive_id, _channel, nil), do: 0

  def campaign_dedup_count(archive_id, channel, batch) do
    {person_ids, _filtered_out} = reachable_person_ids(archive_id, channel)
    contacts = campaign_contacts(batch)

    person_ids
    |> persons_by_id()
    |> Map.values()
    |> Enum.count(&contact_hit?(contacts, &1))
  end

  @doc """
  重发资格校验（R5 拒绝表；MCP 确认流第一段与页面确认预览共用口径）：
  返回 `{:ok, person}` 或带原因业务错误（not_found / already_deleted /
  unsubscribed / claimed）。
  """
  @spec validate_resend_for_person(String.t()) ::
          {:ok, Person.t()} | {:error, %{code: String.t(), message: String.t()}}
  def validate_resend_for_person(person_id) do
    with {:ok, person} <- fetch_person(person_id),
         :ok <- validate_resendable(person) do
      {:ok, person}
    end
  end

  @doc """
  通道就绪校验（R6 第二道闸，MCP 确认段与 GraphQL 面共用）：仅短信档要求
  SendCloud 触达模板就绪；未就绪 → 显式错误（不静默零入队）。
  """
  @spec ensure_channel_ready(atom()) :: :ok | {:error, String.t()}
  def ensure_channel_ready(:sms) do
    if sms_configured?() do
      :ok
    else
      {:error, "sms channel not configured: template must be registered in SendCloud first"}
    end
  end

  def ensure_channel_ready(_), do: :ok

  @doc """
  通道字符串 → atom（R11；GraphQL/MCP 面共用，未知值 fail-closed）。
  """
  @spec parse_channel(String.t()) :: {:ok, atom()} | {:error, :invalid_channel}
  def parse_channel("all"), do: {:ok, :all}
  def parse_channel("email"), do: {:ok, :email}
  def parse_channel("sms"), do: {:ok, :sms}
  def parse_channel(_), do: {:error, :invalid_channel}

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

  defp fetch_person(person_id) do
    Person
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^person_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, %{code: "flashback_person_not_found"}}
      {:ok, person} -> {:ok, person}
      {:error, reason} -> {:error, reason}
    end
  end

  # R5 拒绝表：删除 > 退订 > 认领（互斥状态，顺序只为错误码确定性）。
  defp validate_resendable(person) do
    cond do
      person.deleted_at ->
        {:error, %{code: "flashback_already_deleted", message: "person deleted"}}

      person.outreach_unsubscribed_at ->
        {:error, %{code: "flashback_person_unsubscribed", message: "person unsubscribed"}}

      # 认领真源 = person.user_id（R27 注册即接管档案，token 同步作废）；
      # claimed_by_user_id 是 token 面字段。
      person.user_id ->
        {:error, %{code: "flashback_person_claimed", message: "person already claimed"}}

      true ->
        :ok
    end
  end

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

  @doc """
  入队模板白名单校验（MCP 工具确认流第一段共用，错误经 dispatch_error_message
  字符串化）。
  """
  @spec validate_template(String.t()) :: :ok | {:error, %{code: String.t(), message: String.t()}}
  def validate_template(template) when template in @templates, do: :ok

  def validate_template(_),
    do: {:error, invalid_input_error("template must be one of #{Enum.join(@templates, "|")}")}

  defp invalid_input_error(message),
    do: %{code: "flashback_invalid_input", message: message, reason: :invalid_input}

  # 可触达 = 所选通道档下有可用通道且未退订（R11 三档；:all = email 优先、
  # phone 需短信模板就绪）。返回 {ids, filtered_out}：解析层被抑制/无通道的
  # 人数计入 skipped（运营面从 enqueue 计数即可读出触达面收窄了多少）。
  defp reachable_person_ids(archive_id, channel) do
    suppressed = suppressed_person_ids()

    {ids, filtered_out} =
      Person
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(archive_event_id == ^archive_id)
      |> Ash.read!(authorize?: false, page: false)
      |> Enum.reduce({[], 0}, fn person, {ids, out} ->
        if MapSet.member?(suppressed, person.id) or channel_for(person, channel) == nil do
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

  defp channel_for(person, :all), do: channel_for(person)

  defp channel_for(person, :email) do
    if present?(person.email), do: :email
  end

  defp channel_for(person, :sms) do
    if present?(person.phone) and sms_configured?(), do: :sms
  end

  defp channel_for(person) do
    cond do
      present?(person.email) -> :email
      present?(person.phone) and sms_configured?() -> :sms
      true -> nil
    end
  end

  defp validate_channel(c) when c in [:all, :email, :sms], do: :ok

  defp validate_channel(_),
    do: {:error, invalid_input_error("channel must be one of all|email|sms")}

  # 触达治理留痕单源（R1/R2）：send/resend 成功各一行，metadata 带场次/模板/
  # 通道/批次/入队计数（非每人一行）。审计失败不阻塞已入队的发送（wrapper
  # 审计哲学同款），error 日志留痕。
  defp log_dispatch_action(action, actor, target_type, target_id, metadata) do
    AdminActionLog.log(%{
      actor_id: actor && Map.get(actor, :id),
      action: action,
      target_type: target_type,
      target_id: target_id,
      result: :success,
      metadata: metadata
    })
    |> case do
      {:ok, _} ->
        :ok

      error ->
        Logger.error("[flashback_outreach] admin action log failed: #{inspect(error)}")
        :ok
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

  # ── campaign 触达面（联系方式级去重；批次边界见 moduledoc） ──────────

  # 已建行（queued/sent——已排定或已发；failed 硬退信不算触达）且所属人未退订
  # 的联系方式集合。结构 %{emails: %{contact => MapSet<person_id>}, phones: 同}
  # ——归属人 id 随键携带：候选人本人的历史行不算命中（幂等重跑落 unique_send
  # skipped 语义），命中的判据是「他人已触达」。
  defp campaign_contacts(batch) do
    Outreach
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(batch == ^batch and status in [:queued, :sent])
    |> Ash.read!(authorize?: false, page: false)
    |> Ash.load!([:person], authorize?: false)
    |> Enum.reject(fn row ->
      is_nil(row.person) or not is_nil(row.person.outreach_unsubscribed_at)
    end)
    |> Enum.reduce(%{emails: %{}, phones: %{}}, fn row, contacts ->
      register_contact(contacts, row.person)
    end)
  end

  defp register_contact(contacts, nil), do: contacts

  defp register_contact(contacts, person) do
    contacts
    |> put_contact(:emails, normalize_email(person.email), person.id)
    |> put_contact(:phones, normalize_contact_phone(person.phone), person.id)
  end

  defp put_contact(contacts, _field, nil, _person_id), do: contacts

  defp put_contact(contacts, field, contact, person_id) do
    update_in(contacts, [field, contact], fn owners ->
      MapSet.put(owners || MapSet.new(), person_id)
    end)
  end

  defp contact_hit?(_contacts, nil), do: false

  defp contact_hit?(contacts, person) do
    owners_hit?(contacts.emails, normalize_email(person.email), person.id) or
      owners_hit?(contacts.phones, normalize_contact_phone(person.phone), person.id)
  end

  defp owners_hit?(_keyed_owners, nil, _person_id), do: false

  defp owners_hit?(keyed_owners, contact, person_id) do
    case Map.get(keyed_owners, contact) do
      nil -> false
      owners -> Enum.any?(owners, &(&1 != person_id))
    end
  end

  defp normalize_email(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> String.downcase(trimmed)
    end
  end

  defp normalize_email(_), do: nil

  # phone 归一与导入侧 person_key 同口径：仅 11 位大陆手机做数字 key（+86 前缀
  # 剥壳）；不可归一的非空值保留原文比对（触达数据不丢），空 → nil。
  defp normalize_contact_phone(value) when is_binary(value) do
    trimmed = String.trim(value)
    digits = String.replace(trimmed, ~r/\D/, "")

    cond do
      trimmed == "" -> nil
      digits =~ ~r/^1\d{10}$/ -> digits
      String.starts_with?(digits, "86") and byte_size(digits) == 13 -> binary_part(digits, 2, 11)
      true -> trimmed
    end
  end

  defp normalize_contact_phone(_), do: nil

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

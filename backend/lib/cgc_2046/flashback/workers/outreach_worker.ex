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

  `reconnect`（唤醒首封）。
  """

  use Oban.Worker,
    queue: :outreach,
    max_attempts: 5,
    unique: [period: 604_800, fields: [:worker, :args], states: :all]

  require Ash.Query
  require Logger

  alias Cgc2046.Accounts.TokenCredential

  alias Cgc2046.Flashback.{
    Outreach,
    Outreach.Dispatch,
    Outreach.Emails,
    Person,
    Token
  }

  alias Cgc2046.Mailer

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
         {:ok, delivered} <- render_and_deliver(template, channel, person, args) do
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
    |> Ash.Query.load(:archive_event)
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

  defp render_and_deliver("reconnect", :email, person, _args) do
    # token 只在 email 腿铸造（明文进链接）；sms 腿无链接不铸——身份凭证表
    # 不留永远用不上的 hash 行。
    with {:ok, plaintext} <- mint_token(person.id),
         email <-
           Emails.reconnect(
             person.email,
             display_name(person),
             occurred_on(person),
             archive_name(person),
             enter_url(plaintext),
             unsub_url(person.id),
             screenshot_url()
           ),
         {:ok, _} <- Mailer.deliver(email) do
      {:ok, :email}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # 短信腿（942116 行业通知模板）：vars = year + brand 两个模板变量（正文
  # 「还记得%year%年报名过 %brand% 吗？……闪念回到当年。」——审核要求去掉
  # 回T退订；退订后续如需平台侧同步，走 SendCloud 上行 webhook 置
  # outreach_unsubscribed_at，当前未接入）。年份或品牌派生不出（场次日期
  # 可空 / 场次名首段不含已知品牌词）→ skip：宁缺毋滥，不发错文案。
  # 模板未配置时入队面已抑制 sms 通道，此处再 fail-closed 一次（配置竞态）。
  defp render_and_deliver("reconnect", :sms, person, _args) do
    if Dispatch.sms_configured?() do
      with {:ok, vars} <- sms_vars(person) do
        Cgc2046.Integrations.SendCloud.Sms.send_template_sms(
          person.phone,
          Dispatch.sms_template_id(),
          vars,
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

  defp render_and_deliver(template, _channel, _person, _args) do
    {:skip, "no_renderer_for_#{template}"}
  end

  # 品牌派生：先按「/」切段取首段再匹配——pilot 场名「Rails Girls / Girls
  # Coding Day 北京」两个品牌词同现，直接 contains 会把 2014 的 Rails Girls
  # 场判成 GCD（GCD 2016 年才有）；首段必是主品牌。段落不含已知品牌词 →
  # nil → skip。值恒 ≤16 字符（SendCloud 变量值上限）。
  defp sms_brand(nil), do: nil

  defp sms_brand(name) do
    name
    |> String.split("/", parts: 2)
    |> hd()
    |> then(fn segment ->
      cond do
        String.contains?(segment, "Girls Coding Day") -> "Girls Coding Day"
        String.contains?(segment, "Rails Girls") -> "Rails Girls"
        true -> nil
      end
    end)
  end

  defp sms_vars(person) do
    year = occurred_on(person)
    brand = sms_brand(archive_name(person))

    if year && brand do
      {:ok, %{"year" => Integer.to_string(year.year), "brand" => brand}}
    else
      {:skip, "sms_vars_missing"}
    end
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

  defp unsub_url(person_id) do
    "#{base_url()}/api/flashback/unsubscribe?t=#{Dispatch.unsubscribe_token(person_id)}"
  end

  defp base_url do
    Application.get_env(:cgc_2046, :web_base_url, "http://localhost:3000")
    |> to_string()
    |> String.trim_trailing("/")
  end

  # 称呼用全名（「你好，王小明：」）；无名字 → nil，模板层兜底「同学」。
  defp display_name(%Person{full_name: full_name})
       when is_binary(full_name) and full_name != "",
       do: full_name

  defp display_name(_), do: nil

  # 本人场次日期（EventArchive.occurred_on 可空，nil 由模板降级「那年」）。
  defp occurred_on(%Person{archive_event: %{occurred_on: d}}), do: d
  defp occurred_on(_), do: nil

  # 本人场次名（EventArchive.name 非空——档案必有归属场次）。
  defp archive_name(%Person{archive_event: %{name: name}}), do: name
  defp archive_name(_), do: nil

  defp screenshot_url, do: "#{base_url()}/flashback/weibo-screenshot.png"

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end

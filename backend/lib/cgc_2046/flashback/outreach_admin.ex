defmodule Cgc2046.Flashback.OutreachAdmin do
  @moduledoc """
  闪念间触达管理查询面（R4/R8/R9，PlatformAdmin 专用口径）。

  与 `AdminStats` 的分工：本模块只服务「触达发送」运营闭环——确认摘要/页面
  预览的通道分布（`preview/2`）、批次历史（`batch_history/1`）、名册视图
  （`roster/3`）。三档口径与 `Dispatch.archive_channel_breakdown/1` 单源
  （KTD2），不在此重复可达性规则。
  """

  import Ecto.Query

  alias Cgc2046.Flashback.EventArchive
  alias Cgc2046.Flashback.Outreach.Dispatch
  alias Cgc2046.Repo

  require Ash.Query

  @roster_limit 500

  @doc """
  批量触达预览（R4 摘要口径）：给定场次与通道档，返回预估入队数、三档分布、
  退订剔除数与短信腿就绪位。不入队、零副作用——MCP 确认摘要与页面预览共用。
  """
  @spec preview(String.t(), atom()) ::
          {:ok,
           %{
             archive_key: String.t(),
             archive_name: String.t(),
             channel: atom(),
             queued: non_neg_integer(),
             email_only: non_neg_integer(),
             sms_only: non_neg_integer(),
             both: non_neg_integer(),
             unsubscribed: non_neg_integer(),
             unreachable: non_neg_integer(),
             sms_ready?: boolean()
           }}
          | {:error, term()}
  def preview(archive_key, channel) when channel in [:all, :email, :sms] do
    with {:ok, archive} <- fetch_archive(archive_key),
         {:ok, breakdown} <- Dispatch.archive_channel_breakdown(archive.id) do
      queued =
        case channel do
          :all -> breakdown.email_only + breakdown.both + breakdown.sms_only
          :email -> breakdown.email_only + breakdown.both
          :sms -> breakdown.sms_only + breakdown.both
        end

      {:ok,
       %{
         archive_key: archive.key,
         archive_name: archive.name,
         channel: channel,
         queued: queued,
         email_only: breakdown.email_only,
         sms_only: breakdown.sms_only,
         both: breakdown.both,
         unsubscribed: breakdown.unsubscribed,
         unreachable: breakdown.unreachable,
         sms_ready: Dispatch.sms_configured?()
       }}
    end
  end

  @doc "场次列表（R7 发送入口数据源，PlatformAdmin）：按举办时间倒序。"
  @spec archives() :: {:ok, [map()]}
  def archives do
    archives =
      EventArchive
      |> Ash.Query.for_read(:read)
      |> Ash.Query.sort(desc: :occurred_on)
      |> Ash.read!(authorize?: false, page: false)
      |> Enum.map(fn a ->
        %{key: a.key, name: a.name, city: a.city, occurred_on: Date.to_iso8601(a.occurred_on)}
      end)

    {:ok, archives}
  end

  @doc """
  场次触达批次历史（R8）：按批次聚合发送计数（通道 × 状态），含 resend-*
  补救批次；`first_at` = 批次最早建行时刻（触发时间近似）。已删除档案的
  历史行保留（发送事实，KTD10 口径）。
  """
  @spec batch_history(String.t()) :: {:ok, [map()]} | {:error, term()}
  def batch_history(archive_key) do
    with {:ok, archive} <- fetch_archive(archive_key) do
      rows =
        from(o in "flashback_outreaches",
          join: p in "flashback_people",
          on: p.id == o.person_id,
          where: p.archive_event_id == ^Ecto.UUID.dump!(archive.id),
          group_by: [o.batch, o.template, o.channel, o.status],
          select: %{
            batch: o.batch,
            template: o.template,
            channel: o.channel,
            status: o.status,
            count: count(o.id),
            first_at: min(o.inserted_at)
          }
        )
        |> Repo.all()

      grouped =
        Enum.group_by(rows, & &1.batch)
        |> Map.new(fn {batch, rows} ->
          template = rows |> hd() |> Map.get(:template)

          channel_counts =
            Map.new(rows, fn row ->
              {{String.to_existing_atom(row.channel), String.to_existing_atom(row.status)},
               row.count}
            end)

          ch = fn c ->
            %{
              queued: channel_counts[{c, :queued}] || 0,
              sent: channel_counts[{c, :sent}] || 0,
              failed: channel_counts[{c, :failed}] || 0
            }
          end

          first_at = rows |> Enum.map(& &1.first_at) |> Enum.min()

          {{first_at, batch},
           %{
             batch: batch,
             template: template,
             email: ch.(:email),
             sms: ch.(:sms),
             first_at: first_at
           }}
        end)

      {:ok,
       grouped
       |> Map.values()
       |> Enum.sort_by(&{&1.first_at, &1.batch}, {:desc, DateTime})}
    end
  end

  @doc """
  场次名册（R9）：全部档案行（含已删除——其个人字段已匿名化，展示删除
  标记而非 PII）带最近一次触达结果；`filter` 支持未认领/已退订/仅短信可达/
  发送失败；`search` 按 full_name 不区分大小写包含。行数以场次规模为上限
  （pilot 344），封顶 `@roster_limit` 防御性截断。
  """
  @spec roster(String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, [map()]} | {:error, term()}
  def roster(archive_key, filter \\ nil, search \\ nil)
      when filter in [nil, "unclaimed", "unsubscribed", "sms_only", "send_failed"] do
    with {:ok, archive} <- fetch_archive(archive_key) do
      people =
        Cgc2046.Flashback.Person
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(archive_event_id == ^archive.id)
        |> Ash.read!(authorize?: false, page: false)

      last_by_person = last_outreach_by_person(people)

      entries =
        Enum.map(people, fn person ->
          last = Map.get(last_by_person, person.id)

          %{
            person_id: person.id,
            full_name: person.full_name,
            email: person.email,
            phone: person.phone,
            claimed: not is_nil(person.user_id),
            participation: Atom.to_string(person.participation),
            unsubscribed: not is_nil(person.outreach_unsubscribed_at),
            deleted: not is_nil(person.deleted_at),
            email_reachable: present?(person.email),
            sms_reachable: present?(person.phone),
            last_outreach: last
          }
        end)

      filtered =
        entries
        |> apply_filter(filter)
        |> apply_search(search)

      {:ok, Enum.take(filtered, @roster_limit)}
    end
  end

  defp apply_filter(entries, nil), do: entries

  defp apply_filter(entries, "unclaimed"),
    do: Enum.filter(entries, &(&1.claimed == false and &1.deleted == false))

  defp apply_filter(entries, "unsubscribed"), do: Enum.filter(entries, & &1.unsubscribed)

  defp apply_filter(entries, "sms_only"),
    do: Enum.filter(entries, &(&1.sms_reachable and not &1.email_reachable and not &1.deleted))

  defp apply_filter(entries, "send_failed"),
    do: Enum.filter(entries, &match?(%{last_outreach: %{status: :failed}}, &1))

  defp apply_search(entries, nil), do: entries

  defp apply_search(entries, search) do
    needle = String.downcase(String.trim(search))

    if needle == "" do
      entries
    else
      Enum.filter(entries, &String.contains?(String.downcase(&1.full_name), needle))
    end
  end

  defp last_outreach_by_person(people) do
    # 裸表查询：UUID 需 16 字节 binary（Ash 读出的 id 是字符串，dump 后绑定）
    ids = Enum.map(people, &Ecto.UUID.dump!(&1.id))

    if ids == [] do
      %{}
    else
      from(o in "flashback_outreaches",
        where: o.person_id in ^ids,
        distinct: [desc: o.person_id, desc: o.inserted_at],
        order_by: [desc: o.person_id, desc: o.inserted_at],
        select: %{
          person_id: o.person_id,
          channel: o.channel,
          status: o.status,
          batch: o.batch,
          inserted_at: o.inserted_at
        }
      )
      |> Repo.all()
      |> Map.new(fn row ->
        {Ecto.UUID.load!(row.person_id),
         %{
           channel: String.to_existing_atom(row.channel),
           status: String.to_existing_atom(row.status),
           batch: row.batch,
           at: row.inserted_at
         }}
      end)
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp fetch_archive(archive_key) do
    EventArchive
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(key == ^archive_key)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, %{code: "flashback_archive_not_found"}}
      {:ok, archive} -> {:ok, archive}
      {:error, reason} -> {:error, reason}
    end
  end
end

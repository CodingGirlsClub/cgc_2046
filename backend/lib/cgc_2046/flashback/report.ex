defmodule Cgc2046.Flashback.Report do
  @moduledoc """
  愿望/留言举报（KTD5 U5）：公开 mutation `flashbackReportWish` 的服务端记录。

  举报 ≠ 踩——KTD5：举报是给运营的治理信号（进队列由人判断），不进
  排序权重，不表「观众不赞同」。preset reason 见 `reason_types/0`；自由补充
  ≤200 字。reporter 三轨 voter：登录 actor 取 `u:<user_id>`；匿名可传 `a:<dev>`。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Flashback

  @reason_types ~w(spam irrelevant scam inappropriate other)

  attributes do
    uuid_primary_key(:id)

    attribute(:target_type, :string, allow_nil?: false, public?: true, writable?: true)
    attribute(:target_id, :uuid, allow_nil?: false, public?: true, writable?: true)
    attribute(:reporter_user_id, :uuid, public?: true, writable?: true)
    attribute(:reporter_voter_key, :string, public?: true, writable?: true)

    attribute(:reason_type, :string, allow_nil?: false, public?: true, writable?: true)
    attribute(:reason_free, :string, public?: true, writable?: true)

    attribute(:status, :string,
      allow_nil?: false,
      default: "pending",
      public?: true,
      writable?: true
    )

    attribute(:acted_at, :utc_datetime_usec, public?: true, writable?: true)
    attribute(:acted_by_user_id, :uuid, public?: true, writable?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([
        :target_type,
        :target_id,
        :reporter_user_id,
        :reporter_voter_key,
        :reason_type,
        :reason_free,
        :status
      ])
    end

    update :update do
      accept([:status, :acted_at, :acted_by_user_id, :reason_free])
    end
  end

  postgres do
    table("flashback_reports")
    repo(Cgc2046.Repo)
  end

  @doc false
  def reason_types, do: @reason_types
end

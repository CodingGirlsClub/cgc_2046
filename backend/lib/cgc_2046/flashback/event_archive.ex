defmodule Cgc2046.Flashback.EventArchive do
  @moduledoc """
  场次档案（死数据）：一场历史活动（如 2014-01-11 Rails Girls 北京）的档案行，
  由一次性导入脚本写入（R22），此后只读。

  `applied_count`（报名数）/ `attended_count`（录取/实际参与数）为导入期统计
  快照，供公开统计层（R32）与看板分线分母参考；与现行 `events` 表无外键关系。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Flashback

  attributes do
    uuid_primary_key(:id)

    # 稳定档案例（如 "2014-01-11-bj"）：导入幂等锚点 + 公开统计层分组键。
    # 格式纪律同 initiative slug（小写 URL 段）。
    attribute(:key, :string, allow_nil?: false, public?: true, writable?: true)
    attribute(:name, :string, allow_nil?: false, public?: true, writable?: true)
    attribute(:city, :string, public?: true, writable?: true)
    attribute(:occurred_on, :date, public?: true, writable?: true)
    attribute(:applied_count, :integer, public?: true, writable?: true)
    attribute(:attended_count, :integer, public?: true, writable?: true)

    # 长廊场次格叙事短标签（原型 D ia-frame-label）：「六城同日」这类故事话；
    # nullable——导入未带的场次长廊只显 when 行。
    attribute(:label, :string, public?: true, writable?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    has_many(:people, Cgc2046.Flashback.Person, destination_attribute: :archive_event_id)
  end

  identities do
    identity(:unique_key, [:key])
  end

  postgres do
    table("flashback_event_archives")
    repo(Cgc2046.Repo)
  end

  validations do
    validate(match(:key, ~r/^[a-z0-9][a-z0-9-]*$/))
  end

  actions do
    defaults([:read])

    # 导入脚本专用（authorize?: false 路径）；运营经 admin 面可见。
    create :create do
      accept([:key, :name, :city, :occurred_on, :applied_count, :attended_count, :label])
    end
  end

  admin do
    resource_group(:flashback)

    table_columns([:id, :key, :name, :city, :occurred_on, :applied_count, :attended_count])
  end

  policies do
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    # 档案是死数据：写仅导入脚本（authorize?: false）与平台管理员兜底。
    policy action_type(:create) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end
end

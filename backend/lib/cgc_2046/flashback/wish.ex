defmodule Cgc2046.Flashback.Wish do
  @moduledoc """
  许愿卡（走廊未来帧）：学员对未来活动的愿望——课程、一本书、任何事。

  `visibility` 二态（R6 提交时定终，KD9 不做转换）：

  - `public`——进走廊「公开的愿望」帧，可附议（WishEndorsement）、可留言
    （WishComment）；附议与留言是给平台的热度信号（KD2：成场由平台线下
    发起，产品内不闭环）。
  - `private`——只出现在许愿人自己的「私人许愿」帧；对其他学员任何路径
    不可见（R9 对外承诺）；平台可读（MCP 治理，R18）。

  `city` 创建时快照许愿人的名册城市（R6 表单两字段，无城市入参；nil 允许
  ——无城市许愿在任何城市钉下都显示）。`content` 去空白非空且 ≤500 字
  （服务端长度防线，同 Likes 先例）。软删：`deleted_at` 置位即从走廊与
  投影消失（KTD4 单源函数）；硬删发生在档案删除级联（PIPL）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Flashback

  attributes do
    uuid_primary_key(:id)

    attribute(:person_id, :uuid, allow_nil?: false, public?: true, writable?: true)
    attribute(:content, :string, allow_nil?: false, public?: true, writable?: true)
    attribute(:visibility, :string, allow_nil?: false, public?: true, writable?: true)
    attribute(:city, :string, public?: true, writable?: true)
    attribute(:deleted_at, :utc_datetime, public?: true, writable?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:person, Cgc2046.Flashback.Person, attribute_writable?: true)
    has_many(:endorsements, Cgc2046.Flashback.WishEndorsement, destination_attribute: :wish_id)
    has_many(:comments, Cgc2046.Flashback.WishComment, destination_attribute: :wish_id)
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:person_id, :content, :visibility, :city])
    end

    update :update do
      accept([:deleted_at])
    end
  end

  postgres do
    table("flashback_wishes")
    repo(Cgc2046.Repo)

    references do
      reference(:person, on_delete: :nothing)
    end
  end
end

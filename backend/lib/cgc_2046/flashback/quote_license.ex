defmodule Cgc2046.Flashback.QuoteLicense do
  @moduledoc """
  金句授权（R31）：每人至多一行（`unique_person`），默认 `:off`（两档皆关）。

  - `:anonymous` 匿名金句——平台从当年答案筛金句匿名传播（姓氏级脱敏）；
  - `:credited` 实名支持——在其上补充现状并实名公开（`credited_note` +
    Person.public_slug 发布，发布入口在 U6）。

  `chosen_quote_span` 指向 `question_key` 对应答案 `raw_text` 的一段
  （grapheme 偏移，结构同 fog span）；越界校验在 U2 mutation 拿得到原文处补齐，
  本资源只钉结构（整数、start >= 0、len > 0）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Flashback

  @levels [:off, :anonymous, :credited]

  attributes do
    uuid_primary_key(:id)

    attribute(:person_id, :uuid, allow_nil?: false, public?: true, writable?: true)

    attribute(:level, :atom,
      allow_nil?: false,
      default: :off,
      public?: true,
      writable?: true,
      constraints: [one_of: @levels]
    )

    # 金句来源答案的键（span 的宿主）。
    attribute(:question_key, :string, public?: true, writable?: true)
    # %{"start" => int, "len" => int}；金句候选只从非雾面句子取（U5 消费）。
    attribute(:chosen_quote_span, :map,
      public?: true,
      writable?: true,
      constraints: [
        fields: [
          start: [type: :integer, allow_nil?: false],
          len: [type: :integer, allow_nil?: false]
        ]
      ]
    )

    # 实名补充：「现在在做什么、想法」（:credited 档才消费）。
    attribute(:credited_note, :string, public?: true, writable?: true)

    # R38 平台下线开关：管理端人工撤下红线内容（无审核流水线）。置位后公开读面
    # （金句墙/实名档案页）立即过滤；本人视图与本人授权档不受影响。
    attribute(:hidden_at, :utc_datetime_usec, public?: true, writable?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:person, Cgc2046.Flashback.Person,
      source_attribute: :person_id,
      destination_attribute: :id,
      define_attribute?: false
    )
  end

  identities do
    identity(:unique_person, [:person_id])
  end

  postgres do
    table("flashback_quote_licenses")
    repo(Cgc2046.Repo)
  end

  actions do
    defaults([:read])

    # U2 flashbackSetQuoteLicense 专用（authorize?: false 路径）。
    create :create do
      accept([:person_id, :level, :question_key, :chosen_quote_span, :credited_note])
      change(&validate_span/2)
    end

    update :update do
      require_atomic?(false)
      accept([:level, :question_key, :chosen_quote_span, :credited_note])
      change(&validate_span/2)
    end

    # R38 管理端下线开关（PlatformAdmin；hidden_at 置位/清空）。
    # 用户面 update 不接受 hidden_at——授权档调整永远动不了下线态。
    update :set_hidden do
      require_atomic?(false)
      accept([:hidden_at])
    end

    # U10 删除级联专用（authorize?: false 路径）。
    destroy(:destroy)
  end

  # 结构校验（整数、start >= 0、len > 0）；nil 放行（默认关）。
  defp validate_span(changeset, _context) do
    case Ash.Changeset.get_attribute(changeset, :chosen_quote_span) do
      nil ->
        changeset

      span when is_map(span) ->
        start = Map.get(span, "start") || Map.get(span, :start)
        len = Map.get(span, "len") || Map.get(span, :len)

        if is_integer(start) and start >= 0 and is_integer(len) and len > 0 do
          changeset
        else
          add_span_error(changeset)
        end

      _ ->
        add_span_error(changeset)
    end
  end

  defp add_span_error(changeset) do
    Ash.Changeset.add_error(
      changeset,
      Ash.Error.Changes.InvalidAttribute.exception(
        field: :chosen_quote_span,
        message: "invalid quote span: start must be >= 0 and len > 0 (grapheme offsets)"
      )
    )
  end

  admin do
    resource_group(:flashback)

    table_columns([:id, :person_id, :level, :question_key, :credited_note, :hidden_at])
  end

  policies do
    policy action_type(:read) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    policy action_type(:create) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end

    policy action_type(:update) do
      authorize_if(Cgc2046.Accounts.Policies.PlatformAdmin)
    end
  end
end

defmodule Cgc2046.Flashback.QuoteLicense do
  @moduledoc """
  金句授权（R31）：每人至多一行（`unique_person`），默认 `:off`（两档皆关）。

  - `:anonymous` 匿名金句——平台从当年答案筛金句匿名传播（姓氏级脱敏）；
  - `:credited` 实名支持——在其上补充现状并实名公开（`credited_note` +
    Person.public_slug 发布，发布入口在 U6）。

  `chosen_quote_spans` 是句子白名单（多选）：每个元素携带自己的宿主
  `question_key` 与区间（grapheme 偏移，结构同 fog span）；消费面
  （金句墙/摘要卡）取首句，选句顺序即优先级。越界校验在 mutation 拿得到
  原文处补齐，本资源只钉结构（整数、start >= 0、len > 0）。
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

    # 句子白名单（多选）：[%{"question_key" => str, "start" => int, "len" => int}]；
    # 金句候选只从非雾面句子取（U5 消费）；首句 = 消费面优先展示句。
    attribute(:chosen_quote_spans, {:array, :map},
      public?: true,
      writable?: true,
      constraints: [
        items: [
          fields: [
            question_key: [type: :string, allow_nil?: false],
            start: [type: :integer, allow_nil?: false],
            len: [type: :integer, allow_nil?: false]
          ]
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

    # R37：每个圈选段一行 Quote（sync_for_license 单一入口维护）。
    has_many(:quotes, Cgc2046.Flashback.Quote)
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
      accept([:person_id, :level, :chosen_quote_spans, :credited_note])
      change(&validate_spans/2)
    end

    update :update do
      require_atomic?(false)
      accept([:level, :chosen_quote_spans, :credited_note])
      change(&validate_spans/2)
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

  # 结构校验（每句:question_key 非空、整数、start >= 0、len > 0）；nil/[] 放行（默认关）。
  defp validate_spans(changeset, _context) do
    case Ash.Changeset.get_attribute(changeset, :chosen_quote_spans) do
      nil ->
        changeset

      spans when is_list(spans) ->
        if Enum.all?(spans, &valid_span?/1), do: changeset, else: add_span_error(changeset)

      _ ->
        add_span_error(changeset)
    end
  end

  defp valid_span?(span) when is_map(span) do
    qk = Map.get(span, "question_key") || Map.get(span, :question_key)
    start = Map.get(span, "start") || Map.get(span, :start)
    len = Map.get(span, "len") || Map.get(span, :len)

    is_binary(qk) and qk != "" and is_integer(start) and start >= 0 and is_integer(len) and
      len > 0
  end

  defp valid_span?(_), do: false

  defp add_span_error(changeset) do
    Ash.Changeset.add_error(
      changeset,
      Ash.Error.Changes.InvalidAttribute.exception(
        field: :chosen_quote_spans,
        message:
          "invalid quote spans: each needs question_key, start >= 0 and len > 0 (grapheme offsets)"
      )
    )
  end

  admin do
    resource_group(:flashback)

    table_columns([:id, :person_id, :level, :credited_note, :hidden_at])
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

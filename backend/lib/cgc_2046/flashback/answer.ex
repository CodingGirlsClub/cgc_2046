defmodule Cgc2046.Flashback.Answer do
  @moduledoc """
  当年答案（原文不可变，KTD4/R16）：一行 = 一问。

  `question_key` 为导入列映射后的稳定键（自由文本如 `self_intro` / `funny_thing`，
  结构化字段如 `os` / `social_media` 也走本表——R7 正面由「自由文本 + 结构化字段
  拼出的我是谁」构成）。`raw_text` 永不改写；对外遮蔽只动 `fog_spans`
  （`Flashback.FogSpans.validate/2` 单源校验）。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Flashback

  attributes do
    uuid_primary_key(:id)

    attribute(:person_id, :uuid, allow_nil?: false, public?: true, writable?: true)
    attribute(:question_key, :string, allow_nil?: false, public?: true, writable?: true)

    # 当年原文（U3 导入期已剥离全部雾面标记后的完整文本）。
    attribute(:raw_text, :string, allow_nil?: false, public?: true, writable?: true)

    # jsonb：[%{"start" => int, "len" => int, "reason" => str?}]，grapheme 偏移；
    # 逐项形状由 FogSpans.validate/2 在 action change 里钉住（含越界/重叠）。
    attribute(:fog_spans, {:array, :map},
      public?: true,
      writable?: true,
      default: []
    )

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
    identity(:unique_person_question, [:person_id, :question_key])
  end

  postgres do
    table("flashback_answers")
    repo(Cgc2046.Repo)
  end

  actions do
    defaults([:read])

    # 导入脚本专用（authorize?: false 路径）。
    create :create do
      accept([:person_id, :question_key, :raw_text, :fog_spans])
      change(&validate_fog/2)
    end

    # U10 删除级联专用（authorize?: false 路径——原文硬删，PIPL 数据清除）。
    destroy(:destroy)

    # U2 flashbackAdjustFog 的落点：只改 spans，raw_text 不可达（不在 accept）。
    update :adjust_fog do
      require_atomic?(false)
      accept([:fog_spans])
      change(&validate_fog/2)
    end
  end

  # 结构/重叠/越界（相对本行 raw_text）校验；原子键与字符串键都过
  # FogSpans.validate 的规范化。
  defp validate_fog(changeset, _context) do
    spans = Ash.Changeset.get_attribute(changeset, :fog_spans) || []
    raw = current_raw_text(changeset)

    case Cgc2046.Flashback.FogSpans.validate(spans, raw) do
      {:ok, normalized} ->
        Ash.Changeset.change_attribute(changeset, :fog_spans, normalized)

      {:error, reason} ->
        Ash.Changeset.add_error(
          changeset,
          Ash.Error.Changes.InvalidAttribute.exception(
            field: :fog_spans,
            message:
              "invalid fog spans (#{reason}): spans must be sorted, non-overlapping grapheme ranges within the text"
          )
        )
    end
  end

  # 越界校验取「写入后将生效的原文」：raw_text 不可变（adjust_fog 不接受），
  # create 时 get_attribute 覆盖了新值，update 时回落数据行。
  defp current_raw_text(changeset) do
    Ash.Changeset.get_attribute(changeset, :raw_text) ||
      Ash.Changeset.get_data(changeset, :raw_text)
  end

  admin do
    resource_group(:flashback)

    table_columns([:id, :person_id, :question_key, :inserted_at])
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

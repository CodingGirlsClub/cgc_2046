defmodule Cgc2046Web.GraphqlSchema.Initiatives do
  @moduledoc """
  公开 Initiative 活动页投影 GraphQL 面（匿名可读，跨租户统一计数口径）。
  """

  use Absinthe.Schema.Notation

  object :public_initiative do
    field(:id, non_null(:id))
    field(:name, non_null(:string))
    field(:slug, non_null(:string))
    field(:hashtag, :string)
    field(:description, :string)
    field(:window_starts_at, :datetime)
    field(:window_ends_at, :datetime)
    field(:status, non_null(:string))
    field(:city_count, non_null(:integer))
    field(:event_count, non_null(:integer))
    field(:confirmed_count, non_null(:integer))
    field(:qualified_event_count, non_null(:integer))
    field(:cities, non_null(list_of(non_null(:public_initiative_city))))
  end

  object :public_initiative_card do
    field(:id, non_null(:id))
    field(:name, non_null(:string))
    field(:slug, non_null(:string))
    field(:hashtag, :string)
    field(:description, :string)
    field(:window_starts_at, :datetime)
    field(:window_ends_at, :datetime)
    field(:status, non_null(:string))
  end

  object :public_initiative_city do
    field(:city, non_null(:string))
    field(:events, non_null(list_of(non_null(:public_initiative_event))))
  end

  object :public_initiative_event do
    field(:id, non_null(:id))
    field(:slug, non_null(:string))
    field(:title, non_null(:string))
    field(:status, non_null(:string))
    field(:visibility, non_null(:string))
    field(:starts_at, :datetime)
    field(:ends_at, :datetime)
    field(:registration_deadline, :datetime)
    field(:venue, :json_string)
    field(:confirmed_count, non_null(:integer))
    field(:min_participants, :integer)
    field(:qualification_status, :string)
    field(:archived, non_null(:boolean))
    field(:qualification_badge, non_null(:string))
    field(:short_by, :integer)

    # 参与条件披露（#627）：缴费槽三态 + 押金明细 + 年龄门槛存在性 + 收费金额锚。
    # 全部来自 Event 已物化快照列（`Initiatives.Public` 的裸 SQL 投影），不暴露规则表。
    field(:payment_mode, non_null(:string))
    field(:deposit, non_null(:public_initiative_deposit))
    field(:min_age, :integer)
    field(:price_range_min_cents, :integer)
  end

  @desc "公开页押金明细（#627）：金额缺失/非正时 amountCents 为 null，enabled 仍 true——绝不显示 ¥0"
  object :public_initiative_deposit do
    field(:enabled, non_null(:boolean))
    field(:amount_cents, :integer)
    field(:refundable_on_check_in, :boolean)
  end

  object :initiative_queries do
    @desc "公开 Initiative 活动页投影；匿名可读，统一跨租户计数口径"
    field :public_initiative, :public_initiative do
      arg(:slug, non_null(:string))

      resolve(fn _, %{slug: slug}, _ ->
        case Cgc2046.Initiatives.Public.get_by_slug(slug) do
          {:ok, payload} -> {:ok, payload}
          {:error, :not_found} -> {:ok, nil}
          {:error, _} -> {:error, [message: "failed to load public initiative", code: "invalid"]}
        end
      end)
    end

    @desc "公开 Initiative 列表；匿名可读"
    field :public_initiatives, non_null(list_of(non_null(:public_initiative_card))) do
      resolve(fn _, _, _ ->
        case Cgc2046.Initiatives.Public.list() do
          {:ok, rows} -> {:ok, rows}
          {:error, _} -> {:error, [message: "failed to load public initiatives", code: "invalid"]}
        end
      end)
    end
  end
end

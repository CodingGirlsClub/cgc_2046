defmodule Cgc2046.Offering.PriceTier do
  @moduledoc """
  报名价格档位配置的纯函数族（缴费闭环 U2，R1/R2）。

  v1 档位 = Event/Course 的 `price_tiers` json 配置（嵌入式，无独立表，
  sponsorship_tier.ex 同款形状）：

      %{
        "id" => uuid,              # 档位稳定标识（下单快照指向它）
        "name" => "早鸟票",        # 档位名
        "amount_cents" => 9900,    # 金额（分，integer，≥1——无 0 元档，
                                   #   免费场景走整场免费或管理员免缴，session-settled）
        "available_until" => "2026-09-01T00:00:00Z"  # 可选停售时间；nil = 长期可售
      }

  下单持档位快照（R3）：Order.tier_snapshot 在下单时物化本 map + 当时金额，
  改价/删档不追溯已生成订单。
  """

  @tier_keys ["id", "name", "amount_cents", "available_until"]

  @doc "结构性校验档位配置（json 列表）。"
  @spec valid?(term()) :: boolean()
  def valid?(tiers) when is_list(tiers), do: Enum.all?(tiers, &valid_tier?/1)
  def valid?(_tiers), do: false

  defp valid_tier?(tier) when is_map(tier) do
    is_binary(tier["id"]) and tier["id"] != "" and
      is_binary(tier["name"]) and tier["name"] != "" and
      is_integer(tier["amount_cents"]) and tier["amount_cents"] >= 1 and
      available_until_well_formed?(tier["available_until"]) and
      Enum.all?(Map.keys(tier), &(&1 in @tier_keys))
  end

  defp valid_tier?(_tier), do: false

  # nil = 长期可售；字符串须可解析为 DateTime（畸形时间在配置期拒绝，
  # 不把解析错误推迟到报名面）。
  defp available_until_well_formed?(nil), do: true

  defp available_until_well_formed?(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _dt, _offset} -> true
      _ -> false
    end
  end

  defp available_until_well_formed?(_), do: false

  @doc "按 id 查档位；不存在返回 {:error, :tier_not_found}。"
  @spec find(term(), String.t() | nil) :: {:ok, map()} | {:error, :tier_not_found}
  def find(_tiers, nil), do: {:error, :tier_not_found}

  def find(tiers, tier_id) when is_list(tiers) and is_binary(tier_id) do
    case Enum.find(tiers, fn tier -> is_map(tier) and tier["id"] == tier_id end) do
      nil -> {:error, :tier_not_found}
      tier -> {:ok, tier}
    end
  end

  def find(_tiers, _tier_id), do: {:error, :tier_not_found}

  @doc "档位当前是否可售（R2：available_until 过去 = 停售；nil/未来 = 可售）。"
  @spec available?(map(), DateTime.t()) :: boolean()
  def available?(tier, now) when is_map(tier) do
    case tier["available_until"] do
      nil ->
        true

      value when is_binary(value) ->
        case DateTime.from_iso8601(value) do
          {:ok, dt, _offset} -> DateTime.compare(dt, now) != :lt
          _ -> false
        end

      _ ->
        false
    end
  end

  @doc "过滤当前可售档位（报名面 availablePriceTiers 计算字段的数据源）。"
  @spec available_tiers(term()) :: [map()]
  def available_tiers(tiers) when is_list(tiers) do
    now = DateTime.utc_now()
    Enum.filter(tiers, &(is_map(&1) and available?(&1, now)))
  end

  def available_tiers(_tiers), do: []
end

defmodule Cgc2046.Offering.PriceTiersValidation do
  @moduledoc """
  `price_tiers` 字段结构校验 + 收费开启配对校验（Ash Resource.Validation）。

  Event/Course 的 create/update 路径复用（Accounts.SponsorshipTiersValidation 同款挂法）：

  - 结构非法（0 元档 / 缺 name / 未知键 / 畸形时间）入库前拒绝；
  - `pricing_enabled: true` 且 `price_tiers` 为空拒绝——收费活动必须配置
    可售档位；`pricing_enabled: false`（默认）与空档位配对通过（R4）；
  - `pricing_enabled: true` ⇒ `starts_at` 必须在位（#543：定价单自助取消
    「活动开始前全额退」的锚点）。Event/Course 共享（两者都有 starts_at）；
    只拦本次写入造成的新违规（存量缺口不锁死无关编辑，DB CHECK 兜底新写）。

  反向不变量「押金开 ⇒ 档位为空」（#597）**不在本模块**：本模块为 Event/Course
  共享，而 Course 无押金列；该判据在 `Cgc2046.Events.PaymentModeValidation`
  （押金是 Event 独有）。不要在本模块加 `deposit_enabled` 分支。
  """

  use Ash.Resource.Validation

  alias Cgc2046.Offering.PriceTier

  @impl true
  def validate(changeset, _opts, _context) do
    pricing_enabled = Ash.Changeset.get_attribute(changeset, :pricing_enabled)
    tiers = Ash.Changeset.get_attribute(changeset, :price_tiers)

    cond do
      not PriceTier.valid?(tiers) ->
        {:error,
         field: :price_tiers,
         message:
           "price tiers must be a list of maps with id/name/amount_cents keys (amount_cents integer >= 1)"}

      pricing_enabled == true and tiers == [] ->
        {:error,
         field: :pricing_enabled, message: "pricing_enabled requires at least one price tier"}

      # #543：定价场 ⇒ starts_at 在位（自助取消退款锚）。只拦本次写入造成的
      # 新违规（pricing/starts_at 任一被改动才校验写后状态；存量缺口行不因
      # 无关编辑被锁死——DB CHECK NOT VALID 兜底所有新写入）。
      pricing_enabled == true and pricing_anchor_touched?(changeset) and
          is_nil(Ash.Changeset.get_attribute(changeset, :starts_at)) ->
        {:error, starts_at_required_error()}

      true ->
        :ok
    end
  end

  defp pricing_anchor_touched?(changeset) do
    Enum.any?([:pricing_enabled, :price_tiers, :starts_at], fn attribute ->
      Ash.Changeset.changing_attribute?(changeset, attribute)
    end)
  end

  @doc """
  `pricing_enabled = true` 要求 starts_at 非空的稳定业务错误（单源，#543）。
  Event/Course 的 handle_write_error/2 把各自 DB CHECK 冲突映射到此同款错误。
  """
  def starts_at_required_error do
    Cgc2046.Errors.BusinessError.exception(
      message: "starts_at is required when pricing is enabled (self-cancel refund anchor)",
      code: "pricing_starts_at_required"
    )
  end
end

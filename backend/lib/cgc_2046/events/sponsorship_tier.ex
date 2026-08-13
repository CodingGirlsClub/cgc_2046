defmodule Cgc2046.Events.SponsorshipTier do
  @moduledoc """
  赞助档位配置的纯函数族（E-3 #48）。

  v1 档位 = Event/Workspace 的 `sponsorship_tiers` json 配置（嵌入式，无独立表）：
  - Event 级：`events.sponsorship_tiers`（本场赞助档位）
  - Workspace 级：`workspaces.sponsorship_tiers`（长期赞助档位）

  档位形状（赞助 doc §5.1 + D5 独占位标记）：

      %{
        "id" => uuid,                 # 档位稳定标识（Sponsorship.tier_id 指向它）
        "name" => "冠名",             # 档位名
        "amount_suggestion" => 10000, # 建议金额（元，integer；可 null，v1 仅登记不收款）
        "benefits" => ["logo 展示位", "鸣谢页"],  # 权益项列表（激活时物化交付行）
        "exclusive" => true           # 独占位标记：同一目标该档位仅允许一个 active 赞助
      }

  独占位语义（D5）：exclusive 档位被激活时，条件 UPDATE 的 NOT EXISTS 守卫保证
  同一目标（Event/Workspace）同一档位至多一个 active Sponsorship（见 sponsorship.ex
  prepare_approve）——双重预定在 DB 层原子拒绝。
  """

  @tier_keys ["id", "name", "benefits", "exclusive"]

  @doc "结构性校验档位配置（json 列表）。"
  @spec valid?(term()) :: boolean()
  def valid?(tiers) when is_list(tiers), do: Enum.all?(tiers, &valid_tier?/1)
  def valid?(_tiers), do: false

  defp valid_tier?(tier) when is_map(tier) do
    is_binary(tier["id"]) and tier["id"] != "" and
      is_binary(tier["name"]) and tier["name"] != "" and
      is_list(tier["benefits"]) and Enum.all?(tier["benefits"], &is_binary/1) and
      is_boolean(tier["exclusive"]) and
      (is_nil(tier["amount_suggestion"]) or is_integer(tier["amount_suggestion"])) and
      Enum.all?(Map.keys(tier), &(&1 in (@tier_keys ++ ["amount_suggestion"])))
  end

  defp valid_tier?(_tier), do: false

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

  @doc "档位权益项列表（物化履约账本的源）。"
  @spec benefits(map()) :: [String.t()]
  def benefits(tier) when is_map(tier), do: Enum.filter(tier["benefits"] || [], &is_binary/1)
  def benefits(_tier), do: []

  @doc "档位是否独占位（D5）。"
  @spec exclusive?(map() | nil) :: boolean()
  def exclusive?(nil), do: false
  def exclusive?(tier) when is_map(tier), do: tier["exclusive"] == true
  def exclusive?(_tier), do: false
end

defmodule Cgc2046.Events.SponsorshipTiersValidation do
  @moduledoc """
  `sponsorship_tiers` 字段结构校验（Ash Resource.Validation）。

  Event/Workspace 的 update/create 路径复用：非法档位配置在入库前拒绝，
  避免后续 Sponsorship 创建/激活时踩到畸形 json（fail-fast 而不是
  activation 时静默 tier_not_found）。
  """

  use Ash.Resource.Validation

  alias Cgc2046.Events.SponsorshipTier

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :sponsorship_tiers) do
      nil ->
        :ok

      tiers ->
        if SponsorshipTier.valid?(tiers) do
          :ok
        else
          {:error,
           field: :sponsorship_tiers,
           message:
             "sponsorship tiers must be a list of maps with id/name/benefits/exclusive keys"}
        end
    end
  end
end

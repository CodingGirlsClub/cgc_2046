defmodule Cgc2046.Mcp.Tools.ListFlashbackStats do
  @moduledoc """
  闪念间看板（U11/R24/KTD10，platform_admin）：四率 + 分线 + 兑换申请队列。

  度量契约（与 `Cgc2046.Flashback.AdminStats.stats/0` 单源）：
  - 分子 = FlashbackTouch 各事件 distinct person；
  - 分母 = 成功送达（outreach status=sent 的 distinct person，硬退信与退订剔除）；
  - 分线 = memory（attended）/ dream（not_selected）。

  返回结构固定：`stats`（memory/dream/overall 各含 delivered 与四事件计数）+
  `redemptions`（兑换申请队列，倒序封顶——channel_note 为用户提交的收款渠道，
  人工处理必需，经 platform_admin 门与 ToolCallLog 审计收口）。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Flashback.AdminStats
  alias Cgc2046.Mcp.Wrapper

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    平台管理员专用：闪念间运营看板。stats 按 memory（参加过）/ dream（未入选）/ overall 分线，给出成功
    送达人数（排除硬退信和退订）与各类互动的去重人数；redemptions 是兑换申请队列（按时间倒序，
    redemption_limit 默认 50、最多 200），其中 channel_note 是用户提交的收款渠道，仅供人工处理兑换。
    """
  end

  schema do
    field(:redemption_limit, :integer, description: "兑换申请队列的返回上限（默认 50，封顶 200）")
  end

  @max_redemptions 200

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "list_flashback_stats", fn _actor, _ws, params ->
        limit = clamp(params["redemption_limit"])

        with {:ok, stats} <- AdminStats.stats(),
             {:ok, redemptions} <- AdminStats.redemptions(limit) do
          {:ok, %{stats: stats, redemptions: redemptions}}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  defp clamp(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_redemptions)
  defp clamp(_), do: 50
end

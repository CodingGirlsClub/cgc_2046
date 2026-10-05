defmodule Cgc2046.Mcp.Tools.ListAcquisitionStats do
  @moduledoc """
  平台级获客归因（Plan 012，platform_admin）：按用户最早登录身份的平台统计
  新用户 / 报名 / 志愿者申请。

  度量契约（与 `Cgc2046.Accounts.AcquisitionStats.stats/1` 单源）：获客平台 =
  该用户最早一条 `user_identities.provider`；无身份 = `"none"`；报名可选按
  `initiative_slug` 过滤到该 Initiative 下的场次。只返回计数（导出纪律同
  `AdminStats`：结构性无 PII）。
  """
  use Anubis.Server.Component,
    type: :tool,
    scopes: ["platform_admin"],
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Accounts.AcquisitionStats

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    平台管理员专用：按获客平台（用户最早一次登录所用的平台：xhs 小红书 / wechat 微信小程序 /
    tt 抖音 / wechat_web 微信网页登录 / none 无平台身份）统计时间窗内的新用户、报名（可按
    initiative_slug 过滤，如 hackerstart1024）与志愿者申请。只返回计数。
    """
  end

  schema do
    field(:since, :string, description: "ISO8601 起始时间，默认 30 天前")
    field(:initiative_slug, :string, description: "只统计挂在该 Initiative 下的场次报名")
  end

  @impl true
  def execute(params, frame) do
    result =
      Cgc2046.Mcp.Wrapper.run(frame, params, "list_acquisition_stats", fn _actor, _ws, params ->
        with {:ok, opts} <- build_opts(params) do
          AcquisitionStats.stats(opts)
        end
      end)
      |> normalize_error()

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  defp build_opts(params) do
    with {:ok, since} <- parse_since(params["since"]) do
      opts = if since, do: [since: since], else: []

      opts =
        if params["initiative_slug"],
          do: Keyword.put(opts, :initiative_slug, params["initiative_slug"]),
          else: opts

      {:ok, opts}
    end
  end

  defp parse_since(nil), do: {:ok, nil}

  defp parse_since(since) when is_binary(since) do
    case DateTime.from_iso8601(since) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _reason} -> {:error, "invalid_input: since must be a valid ISO8601 timestamp"}
    end
  end

  defp normalize_error({:error, :initiative_not_found}),
    do: {:error, "acquisition_stats_initiative_not_found: initiative_slug not found"}

  defp normalize_error(result), do: result
end

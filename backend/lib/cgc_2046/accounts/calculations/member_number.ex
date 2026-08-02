defmodule Cgc2046.Accounts.Calculations.MemberNumber do
  @moduledoc """
  P1 平台级成员编号计算（确定性、无存储）。

  由用户 id（uuid 字符串）确定性生成，格式 `CGC-XXXXXX`：
  - 取 uuid 去掉连字符后的前 6 位十六进制字符，转大写；
  - 同一用户永远得到同一编号，不同用户冲突概率极低；
  - 不落库、无需迁移 backfill，天然覆盖存量 + 新注册用户。

  说明：设计稿 mock 为工作区级编号（如 `CGC-SH-0018`）；真实模式下用户跨
  工作区，采用平台级编号更合理。前端仅展示，不参与权限/业务判定。
  """

  use Ash.Resource.Calculation

  @impl true
  def calculate(records, _opts, _context) do
    Enum.map(records, fn record ->
      case record.id do
        nil ->
          nil

        id when is_binary(id) ->
          hex = id |> String.replace("-", "") |> String.slice(0, 6) |> String.upcase()
          "CGC-" <> hex

        _ ->
          nil
      end
    end)
  end
end

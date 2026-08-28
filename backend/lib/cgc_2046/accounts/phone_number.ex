defmodule Cgc2046.Accounts.PhoneNumber do
  @moduledoc """
  手机号归一化单源（plan 2026-08-19-002 D5）：产出 `"+区号号码"` 规范形。

  全平台唯一归一化实现——小程序负载解析（`Cgc2046.Integrations.Wechat.Client`）与
  web 端手机号/邮箱登录共用，禁止第二套实现（防同一号码锚出
  `"+86138…"` 与 `"138…"` 两个 User 的分裂风险）。

  规则（与原 `normalize_phone/2` 严格一致，默认区号 86）：

  - 剥全部非数字字符；本地号已以区号开头（数字以 cc 开头）时不重复拼接；
  - 数字为空或 cc 为空 → `{:error, :invalid}`（fail-closed，宁可拒绝也不猜）。
  """

  @default_country_code "86"

  @doc """
  归一化手机号（默认区号 +86）：web 登录入参等无区号上下文的场景。

      {:ok, "+8613800138000"} = normalize("138-0013-8000")
      {:ok, "+8613800138000"} = normalize("+86 13800138000")
  """
  @spec normalize(term()) :: {:ok, String.t()} | {:error, :invalid}
  def normalize(raw), do: normalize(raw, @default_country_code)

  @doc """
  归一化手机号（显式区号）：小程序负载 `purePhoneNumber + countryCode` 场景。
  """
  @spec normalize(term(), term()) :: {:ok, String.t()} | {:error, :invalid}
  def normalize(raw, country_code) do
    digits = raw && String.replace(to_string(raw), ~r/\D/, "")
    cc = country_code && String.replace(to_string(country_code), ~r/\D/, "")

    cond do
      digits in [nil, ""] -> {:error, :invalid}
      cc in [nil, ""] -> {:error, :invalid}
      String.starts_with?(digits, cc) -> {:ok, "+" <> digits}
      true -> {:ok, "+" <> cc <> digits}
    end
  end
end

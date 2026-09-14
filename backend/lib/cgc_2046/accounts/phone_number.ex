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

  # ITU-T E.164 已分配国家码（前缀无关码：任一已分配国家码都不是另一国家码的
  # 前缀，故最长前缀匹配即唯一解析）。`parse/1` 用作 `+` 前缀输入的合法性门禁。
  @country_codes ~w(
    1 7 20 27 30 31 32 33 34 36 39 40 41 43 44 45 46 47 48 49
    51 52 53 54 55 56 57 58 60 61 62 63 64 65 66 81 82 84 86
    90 91 92 93 94 95 98
    211 212 213 216 218 220 221 222 223 224 225 226 227 228 229
    230 231 232 233 234 235 236 237 238 239 240 241 242 243 244
    245 246 248 249 250 251 252 253 254 255 256 257 258 260 261
    262 263 264 265 266 267 268 269 290 291 297 298 299
    350 351 352 353 354 355 356 357 358 359 370 371 372 373 374
    375 376 377 378 380 381 382 383 385 386 387 389 420 421 423
    500 501 502 503 504 505 506 507 508 509 590 591 592 593 594
    595 596 597 598 599 670 672 673 674 675 676 677 678 679 680
    681 682 683 685 686 687 688 689 690 691 692 800 808 850 852
    853 855 856 870 878 880 881 882 883 888 886 960 961 962 963
    964 965 966 967 968 970 971 972 973 974 975 976 977 992 993
    994 995 996 998
  ) |> MapSet.new()

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

  @doc """
  web 端手机号入参单入口：`+` 开头按 E.164 解析（国际号码，国家码前缀
  必须是已分配国家码）；其余走 `normalize/1`（默认 +86，国内裸号习惯）。
  产出与 normalize 同一规范形 `+区号号码`，命中同一 User 锚与限流 key。

      {:ok, "+14155552671"} = parse("+14155552671")
      {:ok, "+447911123456"} = parse("+44 7911 123456")
      {:ok, "+8613800138000"} = parse("138-0013-8000")
  """
  @spec parse(term()) :: {:ok, String.t()} | {:error, :invalid}
  def parse(raw) do
    trimmed = raw && String.trim(to_string(raw))

    if is_binary(trimmed) and String.starts_with?(trimmed, "+") do
      parse_e164(trimmed)
    else
      normalize(raw)
    end
  end

  # E.164 整号解析：剥非数字后须以已分配国家码开头，其余部分非空。
  # 与 normalize 同一宽松度（不校验号段/长度，严格校验在前端 libphonenumber-js）。
  defp parse_e164("+" <> rest) do
    digits = String.replace(rest, ~r/\D/, "")

    if valid_country_code?(digits), do: {:ok, "+" <> digits}, else: {:error, :invalid}
  end

  defp valid_country_code?(digits) when digits != "" do
    MapSet.member?(@country_codes, String.slice(digits, 0, 3)) or
      MapSet.member?(@country_codes, String.slice(digits, 0, 2)) or
      MapSet.member?(@country_codes, String.slice(digits, 0, 1))
  end

  defp valid_country_code?(_), do: false

  @doc """
  显示掩码（2026-09-08 架构评审候选③自 GraphqlSchema 抽离）：前 6 字符 +
  `****` + 后 4（`+8615578793094` → `+86155****3094`）；异常短号
  （normalize 已保证 +区号号码，理论不可达）全掩码防泄露。
  """
  @spec mask(String.t() | nil) :: String.t() | nil
  def mask(nil), do: nil

  def mask(phone) when is_binary(phone) do
    if String.length(phone) > 10 do
      String.slice(phone, 0, 6) <> "****" <> String.slice(phone, -4, 4)
    else
      String.duplicate("*", String.length(phone))
    end
  end
end

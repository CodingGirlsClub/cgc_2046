defmodule Cgc2046.Flashback.Cities do
  @moduledoc """
  全国地级以上城市名单（KTD11；G18 用户拍板 DataV 上游）。

  数据派生规则：

  - 数据源：`https://geo.datav.aliyun.com/areas_v3/bound/{adcode}_full.json`，
    31 个省级 + 港澳台顶级映射，离线一次性脚本派生
    （`backend/priv/scripts/derive_cities.py`，不在 CI 跑）。
  - 派生口径：每个省级 *_full 中 `level=city` 的 features；港澳台三条手工映射；
    4 直辖市手动补（北京/天津/上海/重庆在 DataV 顶级节段）。
  - 短名归一：长名按后缀列表 strip（「市/地区/盟/自治州/特别行政区/...」），
    至少保留 2 字核心段；`成都市→成都`、`湘西土家族苗族自治州→湘西`。
  - 拼音：pypinyin 离线派生（`pinyin` 短名拼音、`fullPinyin` 全名拼音，不带调）。
  - 经纬度：`center: [lng, lat]`，G9 与 `china-geo.json` 同形状。

  版本指纹：JSON 文件头 `metadata.citiesMd5`，`cityCount` 兜底断言（~370 条）。
  """

  @external_resource "priv/flashback/china_cities.json"

  data =
    "priv/flashback/china_cities.json"
    |> File.read!()
    |> Jason.decode!()

  cities =
    Map.get(data, "cities")
    |> Enum.map(fn c ->
      %{
        adcode: c["adcode"],
        short_name: c["shortName"],
        full_name: c["fullName"],
        pinyin: c["pinyin"],
        full_pinyin: c["fullPinyin"],
        lng_lat: c["center"],
        parent_adcode: c["parentAdcode"]
      }
    end)

  metadata = Map.get(data, "metadata", %{})

  @cities cities
  @metadata metadata

  # 「市/地区/盟/自治州/特别行政区」等后缀——归一时同时尝试全名→短名映射。
  # 与 derive_cities.py 的 SUFFIXES 保持同源。
  @suffixes [
    "布依族苗族自治州",
    "苗族侗族自治州",
    "土家族苗族自治州",
    "藏族羌族自治州",
    "蒙古族藏族自治州",
    "哈尼族彝族自治州",
    "傣族景颇族自治州",
    "傈僳族自治州",
    "壮族苗族自治州",
    "傣族佤族自治州",
    "哈萨克自治州",
    "柯尔克孜自治州",
    "朝鲜族自治州",
    "回族自治州",
    "藏族自治州",
    "彝族自治州",
    "白族自治州",
    "蒙古族自治州",
    "蒙古自治州",
    "回族自治州",
    "特别行政区",
    "自治州",
    "自治区",
    "地区",
    "盟",
    "市",
    "州"
  ]

  @candidates_limit 3

  @doc """
  `list/0`：稳定名单（~370 条）。字段：

  - `adcode` / `short_name` / `full_name` / `pinyin` / `full_pinyin` / `parent_adcode`
  - `lng_lat: [lng, lat]`（GeoJSON 形状）
  """
  @spec list() :: list(map())
  def list, do: @cities

  @doc false
  def metadata, do: @metadata

  @doc """
  `normalize/1`：自由文本 → 名单内短名。

  1. trim（含全角空格/NBSP/BOM）
  2. 精确命中 `short_name` 或 `full_name` → `{:ok, short_name}`
  3. 后缀归一：剩尾剥市/地区/盟/自治州等 → 重新精确匹配 → 命中 → `{:ok, short_name}`
  4. 否则 `{:error, %{code: "flashback_wish_city_unknown", candidates: [...]}}`，
     候选为按前缀、子串、拼音前缀排序的 ≤3 个短名
  """
  @spec normalize(binary() | nil) ::
          {:ok, binary()}
          | {:error, %{code: binary(), candidates: list(binary())}}
  def normalize(nil) do
    {:error, %{code: "flashback_wish_city_unknown", candidates: []}}
  end

  def normalize(input) when is_binary(input) do
    trimmed = clean_input(input)

    cond do
      trimmed == "" ->
        {:error, %{code: "flashback_wish_city_unknown", candidates: []}}

      String.length(trimmed) > 32 ->
        {:error, %{code: "flashback_wish_city_unknown", candidates: []}}

      true ->
        case exact_match(trimmed) do
          {:ok, short} ->
            {:ok, short}

          :error ->
            case suffix_normalize(trimmed) do
              {:ok, short} -> {:ok, short}
              :error -> {:error, city_unknown_error(trimmed)}
            end
        end
    end
  end

  def normalize(_), do: {:error, %{code: "flashback_wish_city_unknown", candidates: []}}

  # ── 内部 ────────────────────────────────────────────────────────────

  # trim 半角/全角空格、NBSP、BOM。只做输入净化，不库改写。
  defp clean_input(s) do
    s
    |> String.trim()
    |> String.replace(~r/^﻿/u, "")
    |> String.replace("　", "")
    |> String.replace(" ", "")
    |> String.trim()
  end

  defp exact_match(trimmed) do
    case Enum.find(@cities, fn c -> c.short_name == trimmed or c.full_name == trimmed end) do
      nil -> :error
      city -> {:ok, city.short_name}
    end
  end

  defp suffix_normalize(trimmed) do
    Enum.reduce_while(@suffixes, :error, fn suf, _acc ->
      if String.ends_with?(trimmed, suf) and String.length(trimmed) > String.length(suf) do
        stripped = String.slice(trimmed, 0, String.length(trimmed) - String.length(suf))

        case exact_match(stripped) do
          {:ok, short} -> {:halt, {:ok, short}}
          :error -> {:cont, :error}
        end
      else
        {:cont, :error}
      end
    end)
  end

  defp city_unknown_error(trimmed) do
    candidates =
      suggest_candidates(trimmed)
      |> Enum.take(@candidates_limit)

    %{
      code: "flashback_wish_city_unknown",
      candidates: candidates,
      message: "没认出这是哪个城市，换个写法试试（如：上海、成都）"
    }
  end

  defp suggest_candidates(trimmed) do
    downcased = String.downcase(trimmed)

    prefix_hit =
      Enum.filter(@cities, fn c ->
        String.starts_with?(c.short_name, trimmed) or String.starts_with?(c.full_name, trimmed)
      end)

    substring_hit =
      Enum.filter(@cities, fn c ->
        String.contains?(c.short_name, trimmed) or String.contains?(c.full_name, trimmed)
      end)
      |> Kernel.--(prefix_hit)

    pinyin_prefix_hit =
      Enum.filter(@cities, fn c ->
        String.starts_with?(c.pinyin, downcased) or String.starts_with?(c.full_pinyin, downcased)
      end)
      |> Kernel.--(prefix_hit)
      |> Kernel.--(substring_hit)

    (prefix_hit ++ substring_hit ++ pinyin_prefix_hit)
    |> Enum.uniq_by(& &1.adcode)
    |> Enum.map(& &1.short_name)
  end
end

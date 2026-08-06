defmodule Mix.Tasks.Cgc2046.CheckLicenses do
  @shortdoc "Fails if any Hex dependency license is incompatible with AGPL-3.0"

  @moduledoc """
  依赖许可证合规检查（AGPL-3.0 兼容性，CI 强制）。

  规则见 `docs/开源合规/依赖引入规则.md`。遍历 `deps/*/mix.exs` 的
  `licenses` 字段做黑名单判断（GPL-2.0 / SSPL / BUSL / Elastic / proprietary /
  无许可声明）。多选声明（数组）中任一项允许即放行；无字段的包查内置映射表。

  ## 用法

      mix cgc2046.check_licenses
  """

  use Mix.Task

  # 无 licenses 字段的已知包 → 实际许可证（mix hex.info 查证，2026-08-05）
  # rebar3 包（fuse/poolboy）许可证在 hex_metadata.config 非 mix.exs，检查器读不到
  @known_no_field %{
    "idna" => "MIT",
    "telemetry" => "Apache-2.0",
    "telemetry_poller" => "Apache-2.0",
    "yamerl" => "BSD-2-Clause",
    "fuse" => "MIT",
    "poolboy" => "ISC"
  }

  # 黑名单：任何一项命中即违规（规则文件 §3）
  @blacklist [
    "gpl-2.0",
    "sspl",
    "busl",
    "elastic",
    "proprietary",
    "commercial"
  ]

  @impl true
  def run(_args) do
    deps = Path.expand("deps", File.cwd!())
    violations = collect_violations(deps)

    if violations == [] do
      Mix.shell().info(
        "✓ All #{length(known_licenses(deps))} deps license-compatible with AGPL-3.0"
      )
    else
      Mix.shell().error("✗ License violations (see docs/开源合规/依赖引入规则.md):")

      Enum.each(violations, fn {name, license} ->
        Mix.shell().error("  #{name}: #{inspect(license)}")
      end)

      exit({:shutdown, 1})
    end
  end

  defp collect_violations(deps) do
    for {name, license} <- known_licenses(deps), blacklisted?(license), do: {name, license}
  end

  defp known_licenses(deps) do
    deps
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.map(&Path.basename/1)
    |> Enum.map(fn name ->
      mix_exs = Path.join([deps, name, "mix.exs"])

      license =
        case File.read(mix_exs) do
          {:ok, content} -> extract_licenses(content)
          _ -> nil
        end

      {name, license || Map.get(@known_no_field, name)}
    end)
  end

  # 提取 mix.exs 的 licenses 字段 → 规范化的小写字符串列表（多选保留全部项）
  defp extract_licenses(content) do
    case Regex.run(~r/licenses:\s*\[([^\]]*)\]/, content) do
      [_, list] ->
        list
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.map(&String.trim(&1, "\""))
        |> Enum.reject(&(&1 == ""))

      nil ->
        nil
    end
  end

  # 黑名单判断（规则文件 §3，严格模式）：
  # - nil / 空列表 → 违规（无有效许可声明）
  # - 字符串 → 规范化后查黑名单子串
  # - 多选列表 → 存在任一项命中黑名单即违规（宁可误报，不可漏报）
  def blacklisted?(licenses) when is_list(licenses) do
    licenses == [] or Enum.any?(licenses, &blacklisted?/1)
  end

  def blacklisted?(nil), do: true
  def blacklisted?(license) when is_binary(license), do: match_blacklist?(license)

  defp match_blacklist?(license) do
    normalized = license |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "-")

    Enum.any?(@blacklist, fn bad ->
      bad = bad |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "-")
      String.contains?(normalized, bad)
    end)
  end
end

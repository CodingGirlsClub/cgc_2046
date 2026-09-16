defmodule Cgc2046.Mcp.ErrorEgressGuardTest do
  @moduledoc """
  #612 MCP 错误出口结构守卫（源码级）。

  为什么需要：MCP 面的 37 处 `Exception.message/1` 是**逐文件**收口的——扫完这一
  轮，下一个新工具仍可能把 `Exception.message(error)` / `inspect(error)` 直接写回
  调用方**或落库**（`ToolCallLog.error_message` 会被 MCP/GraphQL/AshAdmin 二次读出，
  而 `Redact` 只洗 `params`），把「索引名 / 约束名 / 表名 / SQL 片段不出面」的纪律
  重新打洞。本测试把「唯一出口」变成结构不变量，而不是靠评审记性。

  六条断言：

  1. `lib/cgc_2046/mcp/**` 内**不得**出现 `Exception.message`（唯一例外 = 出口模块
     `errors.ex` 自身）；
  1b. 不得在非 Logger 行出现 `Exception.format(`（错误原文只进服务端日志，或经
     `DatabaseError.report/1`）；
  2. `inspect(` 只允许出现在**显式白名单**文件里（每项注明理由，均为人工核对过的
     非错误用法：入参回显 / Logger 留痕 / 长度估算）；某文件多出一处即红灯；
  2b. 白名单文件内也不得 `inspect(error|err|errors)`（Logger 除外），堵「同文件换
     参数」的绕法；
  3. 正向：**每个执行 Ash 写（`Ash.create|update|destroy`）的工具**必须调用
     `Cgc2046.Mcp.Errors.message(`；走域函数写库的 `assign_event_moderator` 显式列入
     豁免并注明理由；
  3b. 审计列写入方 `wrapper.ex` 必须经 `Mcp.Errors.audit_message(`，且本文件不得
     自行 `Exception.message` / `Exception.format` / 非 Logger 的 `inspect`。

  非目标：不扫 `lib/cgc_2046/`（domain）与 `lib/cgc_2046_web/`——GraphQL 面由
  `AshGraphql.Error` impl 覆盖，domain 共享层由
  `Cgc2046.Errors.DatabaseError.safe_message/2` 收口（见
  `test/cgc_2046/errors/database_error_test.exs`）。
  """

  use ExUnit.Case, async: true

  @mcp_root Path.expand("../../../lib/cgc_2046/mcp", __DIR__)
  @egress_module "errors.ex"
  @egress_call "Cgc2046.Mcp.Errors.message("

  # inspect( 白名单：相对路径 → {上限, 理由}
  @inspect_allowlist %{
    "confirmation.ex" => {2, "仅 Logger.error（内部留痕，不回调用方、不落库）"},
    "playbooks.ex" => {1, "Logger.warning 里的文件路径"},
    "redact.ex" => {1, "byte_size(inspect(value)) 长度估算"},
    "tools/approve_join_request.ex" => {1, "回显非法角色入参（非错误树）"},
    "tools/assign_roles.ex" => {3, "回显角色入参（非错误树）"},
    "tools/create_invitation.ex" => {1, "回显非法角色入参（非错误树）"},
    "tools/get_role_playbook.ex" => {1, "回显 role 入参（非错误树）"},
    "tools/learner_journey.ex" => {1, "回显 kind 入参（非错误树）"},
    "tools/public_offering.ex" => {1, "回显 kind 入参（非错误树）"},
    "tools/submit_learning_attempt.ex" => {7, "objective/作答域值回显 + 一处 Logger.warning（非错误树）"},
    "tools/update_prep_policy.ex" => {2, "回显 patch 域值（非错误树）"},
    "wrapper.ex" => {1, "Logger.error（ToolCallLog 写失败留痕，不回调用方、不落库）"}
  }

  # 正向断言的豁免：不直接调 Ash 写、而是经域函数写库（#612 收口时逐个人工核对）
  @domain_write_exemptions [
    # Moderators.assign/3 内部做 Ash.create；工具层错误出口已走统一 helper
    "tools/assign_event_moderator.ex"
  ]

  test "1) MCP 树内不得直接 Exception.message（唯一例外 = 出口模块）" do
    offenders =
      for {rel, source} <- sources(),
          rel != @egress_module,
          String.contains?(source, "Exception.message") do
        rel
      end

    assert offenders == [],
           "以下文件绕过 #{@egress_call} 直接 Exception.message（未映射 DB 错误会带出库内文本）：#{inspect(offenders)}"
  end

  test "2) inspect( 仅出现在显式白名单文件内且不超上限" do
    offenders =
      for {rel, source} <- sources(),
          count = inspect_count(source),
          count > 0,
          not allowlisted?(rel, count) do
        {rel, count, Map.get(@inspect_allowlist, rel)}
      end

    assert offenders == [],
           "inspect( 越界（新用法请先人工核对「非错误树」再登记白名单 + 理由）：#{inspect(offenders)}"
  end

  test "2b) 白名单文件内不得 inspect 错误变量本身（堵「同文件换参数」的绕法，Logger 除外）" do
    offenders =
      for {rel, source} <- sources(),
          rel != @egress_module,
          {line, no} <- source |> String.split("\n") |> Enum.with_index(1),
          Regex.match?(~r/\binspect\(\s*(error|err|errors)\s*\)/, line),
          not logger_line?(source, no) do
        {rel, no, String.trim(line)}
      end

    assert offenders == [],
           "白名单文件内把 inspect(…) 换成了 inspect(错误变量)（非 Logger 留痕即为出口泄漏）：#{inspect(offenders)}"
  end

  test "1b) MCP 树内不得直接 Exception.format 错误原文（原文只进 Logger / DatabaseError）" do
    offenders =
      for {rel, source} <- sources(),
          {line, no} <- source |> String.split("\n") |> Enum.with_index(1),
          String.contains?(line, "Exception.format("),
          not logger_line?(source, no) do
        {rel, no, String.trim(line)}
      end

    assert offenders == [],
           "以下位置把 Exception.format 的原文写进了非日志出口（应收口到 DatabaseError.report/1）：#{inspect(offenders)}"
  end

  test "3) 每个执行 Ash 写的工具都必须走统一出口（tools/ 全量 + 确认流）" do
    missing =
      for {rel, source} <- sources(),
          egress_scope?(rel),
          rel not in @domain_write_exemptions,
          Regex.match?(~r/\bAsh\.(create|update|destroy)\(/, source),
          not String.contains?(source, @egress_call) do
        rel
      end

    assert missing == [],
           "以下工具执行 Ash 写但未经 #{@egress_call} 收口错误：#{inspect(missing)}"
  end

  test "3b) 审计列写入（Wrapper）必须走 audit_message，且本文件不得自行格式化错误" do
    {_rel, source} = Enum.find(sources(), fn {rel, _} -> rel == "wrapper.ex" end)

    assert String.contains?(source, "Cgc2046.Mcp.Errors.audit_message("),
           "wrapper.ex 的审计列写入未经 audit_message 收口（ToolCallLog.error_message 会被二次读出）"

    # 审计列落库路径自己再 inspect/format 错误原文 = 绕过固定摘要（#612 第二条泄漏通道）
    refute String.contains?(source, "Exception.message("),
           "wrapper.ex 不得自行 Exception.message 错误（应经 Mcp.Errors）"

    refute String.contains?(source, "Exception.format("),
           "wrapper.ex 不得自行 Exception.format 错误原文（原文只进日志）"

    offenders =
      source
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, no} ->
        Regex.match?(~r/\binspect\(/, line) and not logger_line?(source, no)
      end)

    assert offenders == [],
           "wrapper.ex 在非 Logger 行 inspect（可能落库）：#{inspect(offenders)}"
  end

  test "4) 白名单项必须先人工核对：理由非空 + 文件存在（防陈旧条目掩盖新用法）" do
    for {rel, {max, reason}} <- @inspect_allowlist do
      assert is_integer(max) and max > 0, "#{rel} 上限非法"
      assert is_binary(reason) and String.trim(reason) != "", "#{rel} 缺理由"
      assert File.exists?(Path.join(@mcp_root, rel)), "#{rel} 白名单条目指向不存在的文件"
    end
  end

  # 扫描视图 = 剥掉整行注释后的源码：注释里为了说明纪律写出 `Exception.message`
  # / `inspect(error)` 字面量不应被当成违规（判据只认可执行代码）。行内尾注释不剥，
  # 取向从严。
  defp sources do
    @mcp_root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      code =
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.map_join("\n", fn line ->
          if line |> String.trim_leading() |> String.starts_with?("#"), do: "", else: line
        end)

      {Path.relative_to(path, @mcp_root), code}
    end)
    |> Enum.sort()
  end

  defp inspect_count(source), do: source |> then(&Regex.scan(~r/\binspect\(/, &1)) |> length()

  # 该行是否处于一次 Logger 调用内（多行 Logger.error("…" <> inspect(error)) 的
  # 续行本身不含 "Logger."，故回看 3 行）。
  defp logger_line?(source, line_no) do
    source
    |> String.split("\n")
    |> Enum.slice(max(line_no - 4, 0), 4)
    |> Enum.join("\n")
    |> String.contains?("Logger.")
  end

  # 出口纪律的适用范围：工具族（tools/**）+ 确认流（confirmation.ex 直接回
  # `{:error, String.t()}` 给工具）。wrapper.ex / token.ex 等基础设施虽也做 Ash
  # 写，但其返回值不是调用方可见的错误串（审计列单独由断言 3b 钉）。
  defp egress_scope?(rel), do: String.starts_with?(rel, "tools/") or rel == "confirmation.ex"

  defp allowlisted?(rel, count) do
    case Map.get(@inspect_allowlist, rel) do
      {max, _reason} -> count <= max
      nil -> false
    end
  end
end

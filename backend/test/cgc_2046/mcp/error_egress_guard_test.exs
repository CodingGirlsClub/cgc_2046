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

  #631 追加三条（覆盖 #612 收尾报告的三个残余，断言编号沿用文件内既有序列）：

  5. 对账发现 `detail` 必须经白名单投影（不得回落为 `detail: finding.detail` 逐字回放）；
  6. 工具层不得 `{:error, x} -> {:error, x}` 原样透传域错误——非二进制错误会在
     `Response.to_response/2` 落 `FunctionClauseError`（`start_learning_run` 的崩溃形状）；
  7. 行为断言：错误类经出口折叠后，**回包与审计列**都不得出现类脚手架 / inspect 形态
     （`Bread Crumbs:` / `Invalid Error` / `Error returned from` / `%Struct{` / `inspect(`）；
     并钉住 `confirmation.ex` 的并发双确认子句同时命中「包在 `%Ash.Error.Invalid{}` 里」
     的 StaleRecord（#631 D4，否则该叶子的 `inspect(resource/filter)` 会出面）。

  文案形状（`database_error` / 已知 code 逐字不变、折叠无脚手架）由
  `test/cgc_2046/errors/database_error_test.exs` 的行为钉负责；本文件负责**结构**。

  #680 追加一条（domain 源码级，编号沿用既有序列）：

  8. `lib/cgc_2046/**` 不得返回 Ash keyword 错误（`{:error, field: ..., message: ...}`）
     ——Ash 的 keyword 转换无条件写 `value: nil` + `has_value?: true`，渲染成
     `Value: nil`（MCP 出口逐叶折叠后对 agent 真实可见，#677 事故同源）。
     #680 收敛基线：AST 扫描命中 14 处 → DP2 删除 1 处不可达兜底
     （workspace_profile 的 `validate_avatar_url(_)`）→ 13 处；DP6 再删 1 处不可达
     空串分支（user.ex，Ash `:string` 默认把空白归一为 nil）→ 12 处全部显式化；
     本守卫期望命中 0，且解析失败必须显式红（不静默跳过，见 keyword_field_error?/1）。
     行为侧由 `test/cgc_2046/errors/invalid_attribute_value_render_test.exs` 的
     12 行站点表钉。

  非目标（#680 修订）：不扫 `lib/cgc_2046_web/`（GraphQL 面由 `AshGraphql.Error`
  impl 覆盖）；`lib/cgc_2046/`（domain）只做第 8 条这一项**错误构造方式**扫描，
  不做出口文本扫描。
  """

  use ExUnit.Case, async: true

  @mcp_root Path.expand("../../../lib/cgc_2046/mcp", __DIR__)
  @domain_root Path.expand("../../../lib/cgc_2046", __DIR__)
  @egress_module "errors.ex"
  @egress_call "Cgc2046.Mcp.Errors.message("

  # #680 收敛基线（有意识改动闸）：AST 全仓扫描命中 14 处 keyword 错误路径 →
  # DP2 删除 1 处不可达兜底（workspace_profile 的 validate_avatar_url(_)）→ 13 处；
  # DP6 再删 1 处不可达空串分支（user.ex）。本守卫期望命中恒为 0；12 与行为覆盖表
  # （invalid_attribute_value_render_test.exs 的 @expected_site_count）双向联动，
  # 改这个数 = 有意识改动。
  @converted_keyword_error_sites 12

  # 域错误原样透传的形状（跨行：`{:error, x} ->\n  {:error, x}`）；#631 前唯一命中
  # = tools/start_learning_run.ex:53（token.ex 同名形状在 egress_scope? 之外，不扫）
  @raw_passthrough ~r/\{:error,\s*([a-z_]+)\}\s*->\s*\{:error,\s*\1\}/

  # 类脚手架 / inspect 形态（回包与审计列都不得出现）：错误类头、面包屑来源行、
  # 结构体渲染（`%Ash.Filter{…}` / `%Postgrex.Error{…}` 等）
  @scaffolding ~r/Bread Crumbs:|Invalid Error|Error returned from|%[A-Z][A-Za-z0-9_.]*\{/

  # inspect( 白名单：相对路径 → {上限, 理由}
  @inspect_allowlist %{
    "confirmation.ex" => {2, "仅 Logger.error（内部留痕，不回调用方、不落库）"},
    "playbooks.ex" => {1, "Logger.warning 里的文件路径"},
    "redact.ex" => {1, "byte_size(inspect(value)) 长度估算"},
    "tools/admin_resend_flashback_outreach.ex" => {2, "未知错误形状字符串化（错误树出口）+ Logger.error 审计留痕"},
    "tools/admin_send_flashback_outreach.ex" => {3, "未知错误形状字符串化（错误树出口）+ Logger.error 审计留痕"},
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

  test "5) 对账发现 detail 必须经白名单投影（#631：不得逐字回放 finding.detail）" do
    {_rel, source} =
      Enum.find(sources(), fn {rel, _} -> rel == "tools/admin_list_reconciliation_findings.ex" end)

    refute String.contains?(source, "detail: finding.detail"),
           "detail 又变回逐字回放（应收口到 project_detail/1：白名单键 + 原文键固定摘要）"

    assert String.contains?(source, "project_detail(finding.detail)"),
           "detail 未经 project_detail/1 投影（白名单/原文摘要缺失）"
  end

  test "6) 工具层不得原样透传域错误（#631：非二进制错误击穿响应出口）" do
    offenders =
      for {rel, source} <- sources(),
          egress_scope?(rel),
          [full | _] <- Regex.scan(@raw_passthrough, source) do
        {rel, full |> String.replace(~r/\s+/, " ") |> String.trim()}
      end

    assert offenders == [],
           "以下位置把域错误原样透传（应经 #{@egress_call} 收口）：非二进制错误会在 " <>
             "Response.to_response/2 落 FunctionClauseError（#631）：#{inspect(offenders)}"
  end

  test "7) 错误类经出口折叠后，回包与审计列都不得出现类脚手架 / inspect 形态（#631）" do
    frame = Anubis.Server.Frame.new(current_user: nil)

    # 生产 `save_course_content` 同形：Ash 类错误 + 带 breadcrumbs 的叶子
    class =
      Ash.Error.to_error_class([
        %Ash.Error.Changes.InvalidChanges{
          message: "objectives required",
          vars: [],
          bread_crumbs: ["Error returned from: Cgc2046.Curriculum.Output.upsert_content"]
        }
      ])

    # 前置：类消息本身带脚手架（Ash 升版改了渲染即在此暴露，而不是静默放行）
    assert Exception.message(class) =~ "Bread Crumbs:"

    # ① 回包（工具返回值）
    message = Cgc2046.Mcp.Errors.message(class, "failed to save course content")
    assert message == "objectives required"
    refute message =~ @scaffolding
    refute message =~ ~r/inspect\(/

    # ② 审计列（ToolCallLog.error_message，二次读出通道）→ 固定摘要 + uuid
    refute Cgc2046.Mcp.Errors.audit_message(class) =~ @scaffolding

    # ③ 响应出口全函数：非二进制错误也必须是有文案的 JSON-RPC error
    assert {:error, %Anubis.MCP.Error{message: response_message}, ^frame} =
             Cgc2046.Mcp.Tools.Response.to_response({:error, :collision_race}, frame)

    assert is_binary(response_message)
    refute response_message =~ @scaffolding

    # ④ 并发双确认的友好子句须同时命中「包在 Invalid 里」的 StaleRecord（D4）：
    # StaleRecord 叶子自身的 message 会 inspect(resource/filter)，不经该子句即出面
    {_rel, confirmation} = Enum.find(sources(), fn {rel, _} -> rel == "confirmation.ex" end)

    assert Regex.match?(
             ~r/Enum\.any\?\(errors,\s*&match\?\(%Ash\.Error\.Changes\.StaleRecord\{\}, &1\)\)/,
             confirmation
           ),
           "confirmation.ex 缺少「Invalid 包裹的 StaleRecord」子句（#631 D4）"
  end

  test "8) domain 自定义校验不得返回 Ash keyword 错误（#680：keyword 转换无条件带 value: nil）" do
    offenders =
      @domain_root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(&keyword_field_error?/1)
      |> Enum.map(&Path.relative_to(&1, @domain_root))
      |> Enum.sort()

    assert offenders == [],
           "以下文件仍返回 keyword 错误（Ash 转换会强制 value: nil，MCP 出口渲染 " <>
             "`Value: nil`，agent 会误判服务端读到 nil；#680 基线 #{@converted_keyword_error_sites} 处" <>
             "已全部显式化，新增自定义校验请用 " <>
             "Ash.Error.Changes.InvalidAttribute.exception(value: Cgc2046.Errors.ValueSummary.describe(...))）：" <>
             inspect(offenders)

    # 收敛基线两侧一致（有意识改动闸）：AST 基线数字 = 行为契约表行数。
    # 增删站点表行必须同步改 @converted_keyword_error_sites，反之亦然。
    assert length(Cgc2046.Errors.InvalidAttributeValueRenderSites.sites()) ==
             @converted_keyword_error_sites,
           "#680 收敛基线两侧不一致：AST 基线 #{@converted_keyword_error_sites} 处 vs " <>
             "行为契约表 #{length(Cgc2046.Errors.InvalidAttributeValueRenderSites.sites())} 行"
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

  # #680 判据走 AST 而非按行 grep：`{:error, field: ...}` 的跨行写法
  # （`{:error,\n  field: ...`，如 workspace_profile 的 MIME 分支）同样命中——
  # 按行 grep 正是 issue 把 14 处漏成「3 处」的原因。
  # 解析失败必须显式红（F2）：静默 skip 会让「守卫看不见的文件」变成假绿。
  defp keyword_field_error?(path) do
    case Code.string_to_quoted(File.read!(path)) do
      {:ok, ast} ->
        {_ast, found?} =
          Macro.prewalk(ast, false, fn
            {:error, kw} = node, acc when is_list(kw) ->
              {node, acc or (Keyword.keyword?(kw) and Keyword.has_key?(kw, :field))}

            node, acc ->
              {node, acc}
          end)

        found?

      {:error, reason} ->
        flunk(
          "domain 源码无法解析，守卫拒绝静默跳过（F2）：" <>
            "#{Path.relative_to(path, @domain_root)}: #{inspect(reason)}"
        )
    end
  end

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

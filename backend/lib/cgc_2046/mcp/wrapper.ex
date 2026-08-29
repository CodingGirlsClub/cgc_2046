defmodule Cgc2046.Mcp.Wrapper do
  @moduledoc """
  MCP 工具调用的统一封装（D-D7 / D-D8 / D9）。

  每个 tool 的 `execute/2` 入口都经 `run/3`：

  1. 从 frame.assigns 取 actor（McpAuthPlug 注入 `:current_user`）
  2. 校验必填 `workspace_id`（D12 无状态作用域；`meta: %{workspace_id: :optional}` 的工具豁免）
  3. membership 鉴权：非成员直接 Forbidden（不经业务 action，快速拒绝）；
     `meta: %{membership: :deferred}` 的工具由工具层授权判定替代；
     `meta: %{membership: :public}` 的工具（公开浏览族，KTD3）跳过 membership
     校验——任何持有效连接 token 的登录用户可用，匿名姿态读在工具层（KTD2）
  4. 执行业务 fun（`fn actor, workspace_id, params -> {:ok, result} | {:error, msg} end`）
  5. 落 ToolCallLog 审计（ok / error / forbidden；带 client_name / session_id 归因维度
     （#228），取不到时落 nil；失败不阻塞响应，记 Logger）

  鉴权立场随工具走（架构深化 C）：豁免声明 = 各工具模块 `use
  Anubis.Server.Component` 的 `meta:` opt，本模块经
  `Cgc2046.Mcp.Server.__components__(:tool)` 派生 name→meta 映射并缓存
  （`:persistent_term` + Server 模块 md5 指纹防陈旧）。**未声明 meta 的工具
  = member-only + workspace_id 必填（fail-closed 默认）**——新工具漏声明
  不会静默放行。

  ## 双面契约（MCP membership 门 vs 平台管理员治理读，刻意不同答）

  - **MCP 面（本模块默认门）**：member-only 门**不含 platform_admin 豁免**——
    非成员平台管理员调 member-only 工具（list_members / get_workflow /
    get_step_output 等）一律 Forbidden。MCP 是自动化 agent 代理面，取最小
    授权：平台管理员的跨租户治理读走 GraphQL admin 查询，不经 agent 直连面。
  - **policy / Rbac 面**：资源 read policy 放行 platform_admin 跨租户治理读取
    （成员列表 / 审计 / 工作流，见 `Cgc2046.Accounts.Policies.PlatformAdmin`
    「双面契约」段与 `Cgc2046.Accounts.Rbac.abilities_for/2`）。

  修改任一面前先读对面——MCP 门若要放宽 admin 豁免，须与
  `Policies.PlatformAdmin`、`Rbac.abilities_for/2`、CONTEXT.md「平台管理员」
  一起裁决，不允许单面放宽。

  确认流工具（D-D3 two-tool）不在此处理 `needs_confirmation`——由
  `Cgc2046.Mcp.Confirmation.request/4` 先行拦截，本模块只负责审计与鉴权。
  """

  alias Anubis.Server.Component.Tool
  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Mcp.Redact
  alias Cgc2046.Mcp.ToolCallLog

  require Logger

  # 派生门控映射的 persistent_term 键；缓存值 = {%{md5: server_md5}, name → meta map}。
  # Server 模块重编译（开发热重载 / 测试重新编译）后 md5 变化即重建，杜绝陈旧缓存。
  @gate_map_key {__MODULE__, :tool_gate_map}

  @type result ::
          {:ok, map() | String.t()}
          | {:error, String.t()}
          | {:needs_confirmation, %{pending_id: String.t(), summary: String.t()}}

  @doc """
  执行一个工具调用。`fun` 签名为 `(actor, workspace_id | nil, params) -> result`。
  """
  @spec run(map(), map(), String.t(), fun()) :: result()
  def run(frame, params, tool_name, fun) do
    started = System.monotonic_time(:millisecond)
    actor = frame.assigns[:current_user]
    workspace_id = params["workspace_id"] || params[:workspace_id]

    result =
      with :ok <- check_actor(actor),
           :ok <- check_workspace_id(tool_name, workspace_id),
           :ok <- check_membership(tool_name, actor, workspace_id) do
        fun.(actor, workspace_id, params)
      end

    log_call(
      frame,
      actor,
      tool_name,
      params,
      result,
      System.monotonic_time(:millisecond) - started
    )

    result
  end

  # ---- 派生门控（架构深化 C：立场随工具走）----

  # `Server.__components__(:tool)` 每次调用经 parse_components 重建 Tool struct
  # + schema + 闭包，非零开销；缓存到 persistent_term，键值带 Server 模块 md5
  # 指纹——模块重编译后 md5 变化即重建，防陈旧。
  defp tool_gate_map do
    case :persistent_term.get(@gate_map_key, nil) do
      {%{md5: md5}, map} ->
        if md5 == server_md5(), do: map, else: rebuild_gate_map()

      _ ->
        rebuild_gate_map()
    end
  end

  defp rebuild_gate_map do
    # md5 须先于 __components__ 读取（advisor F1）：若两步间 Server 被重编译，
    # 错向存储 {旧 md5, 新 map} 会被下次 md5 检查发现并自愈；反向（新 md5 +
    # 旧 map）则被误判新鲜，缓存永久陈旧不可自愈。
    md5 = server_md5()

    map =
      Cgc2046.Mcp.Server.__components__(:tool)
      |> Map.new(fn %Tool{name: name, meta: meta} -> {name, meta} end)

    :persistent_term.put(@gate_map_key, {%{md5: md5}, map})
    map
  end

  defp server_md5, do: Cgc2046.Mcp.Server.__info__(:md5)

  defp meta_for(tool_name), do: Map.get(tool_gate_map(), tool_name)

  defp workspace_id_optional?(tool_name),
    do: match?(%{workspace_id: :optional}, meta_for(tool_name))

  defp check_actor(nil), do: {:error, "unauthenticated: valid MCP connection token required"}
  defp check_actor(_actor), do: :ok

  defp check_workspace_id(tool_name, workspace_id) do
    if workspace_id_optional?(tool_name) or is_binary(workspace_id) do
      :ok
    else
      {:error, "forbidden: workspace_id is required for tool #{tool_name} (D12 stateless scope)"}
    end
  end

  # 门控家族判定（gate test 可观察面，KTD3）：map 模式是子集匹配，
  # `%{workspace_id: :optional, membership: :public}` 同时命中 :public 与
  # :optional 两个模式——`:public` 子句必须置于 `:optional` 之前，追加在后即为
  # 永不命中的死子句。分支顺序 = 语义，由 wrapper_gate_test 钉死。
  @doc false
  @spec gate_family(String.t()) :: :public | :optional | :deferred | :member_only
  def gate_family(tool_name) do
    case meta_for(tool_name) do
      # 公开浏览工具族：任何持连接 token 的登录用户可读公开面（KTD2/KTD3）
      %{membership: :public} -> :public
      # 确认流承载工具（鉴权在 Confirmation 内做，pending 归属校验即授权）+
      # actor 锚定跨工作台读（S1：list_my_workspaces / get_role_playbook
      # 双键同命中本分支，无单一 workspace 可作门，授权在工具层）
      %{workspace_id: :optional} -> :optional
      # 成员门槛由工具层授权判定替代（save_step_output 学员 / 课程三学员侧工具）
      %{membership: :deferred} -> :deferred
      # 默认 fail-closed：member-only + workspace_id 必填
      _ -> :member_only
    end
  end

  defp check_membership(tool_name, actor, workspace_id) do
    case gate_family(tool_name) do
      # 公开浏览工具族：跳过 membership 校验（匿名姿态读在工具层，KTD2）
      :public ->
        :ok

      # 确认流承载工具（鉴权在 Confirmation 内做，pending 归属校验即授权）+
      # actor 锚定跨工作台读（list_my_workspaces / get_role_playbook，工具层授权）
      :optional ->
        :ok

      # 成员门槛由工具层授权判定替代（save_step_output 学员 / 课程三学员侧工具；
      # 见各工具 moduledoc——工具内判定 + 资源层 policy 双重门禁）
      :deferred ->
        :ok

      # 默认 fail-closed：member-only + workspace_id 必填
      :member_only ->
        case MembershipContext.membership_of(actor, workspace_id) do
          nil -> {:error, "forbidden: not a member of workspace #{workspace_id}"}
          _membership -> :ok
        end
    end
  end

  # 审计落库失败不阻塞工具响应（审计可用性 < 工具可用性），但记 error 日志留痕
  defp log_call(_frame, nil, _tool, _params, _result, _latency), do: :ok

  defp log_call(frame, actor, tool_name, params, result, latency_ms) do
    {status, error_message, pending_id} = classify(result)

    ToolCallLog
    |> Ash.Changeset.for_create(
      :log,
      %{
        user_id: actor.id,
        tool: tool_name,
        params: Redact.call(params || %{}),
        result_status: status,
        error_message: error_message && String.slice(error_message, 0, 500),
        latency_ms: latency_ms,
        pending_operation_id: pending_id,
        client_name: client_name(frame),
        session_id: mcp_session_id(frame)
      },
      authorize?: false
    )
    |> Ash.create()
    |> case do
      {:ok, _} ->
        :ok

      {:error, error} ->
        Logger.error("[Mcp.Wrapper] ToolCallLog write failed for #{tool_name}: #{inspect(error)}")
        :ok
    end
  end

  # ---- 归因维度取值（#228）----
  # frame.context 由 anubis Session 每次回调前重建（只读）：
  # - client_info 来自 initialize 的 clientInfo（JSON 解码，string keys）
  # - session_id 来自会话标识（HTTP = Mcp-Session-Id；stdio 恒为 "stdio"）
  # pattern match 兜底：任何形状取不到即落 nil，审计主路径不因缺维度失败

  defp client_name(%{context: %{client_info: %{"name" => name}}}) when is_binary(name), do: name
  defp client_name(_frame), do: nil

  defp mcp_session_id(%{context: %{session_id: session_id}}) when is_binary(session_id),
    do: session_id

  defp mcp_session_id(_frame), do: nil

  defp classify({:ok, _}), do: {:ok, nil, nil}
  defp classify({:error, msg}) when is_binary(msg), do: classify_error(msg)
  defp classify({:error, err}), do: {:error, inspect(err) |> String.slice(0, 500), nil}

  defp classify({:needs_confirmation, %{pending_id: pending_id}}),
    do: {:needs_confirmation, nil, pending_id}

  defp classify_error(msg) do
    if String.starts_with?(msg, "forbidden") do
      {:forbidden, msg, nil}
    else
      {:error, msg, nil}
    end
  end
end

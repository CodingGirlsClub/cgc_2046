defmodule Cgc2046.Mcp.Scopes do
  @moduledoc """
  MCP 工具可见性分层（#1085，ADR-0021）：`tools/list` 只列调用者所属最高层累计可见的工具，
  越层 `tools/call` 在 anubis 层即被拒绝。

  ## 机制

  工具经 `use Anubis.Server.Component, type: :tool, scopes: [...]` 声明所需 scope。anubis 的
  `tools/list` 隐藏 scope 不够的工具、`tools/call` 拒绝调用（`insufficient_scope`），判据是
  `frame.context.auth.scopes`。本平台不走 OAuth（`authorization:` 配置要授权服务器地址、校验
  `aud`，且让每个请求校验两次 token），所以由 `Cgc2046.Mcp.Server` 挂的 `__before_compile__`
  钩子在 `tools/list` / `tools/call` 入口把 scope 注入 frame。scope 每个请求按 `current_user`
  重算，角色变更下一个请求即生效，不存会话状态（D12）。

  钩子必须在 `use Anubis.Server` **之后**挂：anubis 在自己的 `__before_compile__` 里才定义
  `handle_request/2`，Server 模块正文里直接覆写它拿不到 `super`（编译失败）。

  ## 分层（scope 名沿用 `get_role_playbook` 的角色名；跨工作台并集）

  | scope | 条件 |
  |---|---|
  | `tutor` | 任一工作台持 tutor / owner / admin |
  | `workspace_admin` | 任一工作台持 owner / admin |
  | `platform_admin` | `is_platform_admin`；同时级联拿前两个（可见面 = 分层前的现状，不回退） |

  **分类原则：可见面不比授权更严**——只要某类用户有可能被授权调用，就不对他隐藏。因此
  `create_invitation`（volunteer 可发邀请）、`list_event_moderators`（活动主理人可读）、
  `approve_prep` 等审核三件套（未指定 reviewer 时任何成员）仍全员可见；授权口径本身是否收窄
  另案跟踪。

  **scope 是粗检查，不替代授权**：Wrapper 的 membership 门、工具层角色判定、数据层 policy
  全部保留。scope 只回答「这个人在任何工作台有没有可能用到这类工具」，具体到哪个工作台仍由
  Wrapper 判定。

  ## 失败方向（均为 fail-closed）

  - 钩子缺失 → 带 scope 的工具对所有人隐藏，而不是对所有人公开；
  - 成员资格读取失败 → `granted/1` 返回 `[]`（只见全员可见名单），不抛、不放行；
  - 工具漏标 scope = 全员可见（anubis 默认）——由 `tool_scopes_test` 的精确名单钉死。

  ## 审计

  被 scope 拒绝的调用在 anubis 层就返回，到不了 `Cgc2046.Mcp.Wrapper.run/4`。
  `translate_denial/2` 把 `insufficient_scope` 译成 `forbidden: ...`（工具描述向 agent 承诺过
  「没权限时错误以 forbidden 开头」），并经 `Wrapper.record_denied/4` 补写 forbidden 审计
  （ADR-0001 D6「每次工具调用 = 审计记录」）。

  ## 已知边界

  - task 增强的 `tools/call`（`Session.Tasks`）直接走 `Handlers.handle`，不经
    `Server.handle_request/2`，会绕过本钩子；Server 当前只声明 `tools` capability，该路径
    不可达，`tool_scopes_test` 钉住不得声明 `tasks`。
  - 每个 `tools/list` / `tools/call` 多一次成员资格查询，与 Wrapper 现有成本同量级。
  """

  alias Anubis.MCP.Error
  alias Anubis.Server.Authorization
  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Accounts.Policies.PlatformAdmin
  alias Cgc2046.Accounts.Role
  alias Cgc2046.Mcp.Errors
  alias Cgc2046.Mcp.Wrapper

  require Logger

  @tutor "tutor"
  @workspace_admin "workspace_admin"
  @platform_admin "platform_admin"

  # scope → 拒绝文案里的角色描述（agent 据此向用户转述缺什么权限）
  @role_phrases %{
    @tutor => "tutor, owner or admin role in a workspace",
    @workspace_admin => "owner or admin role in a workspace",
    @platform_admin => "platform admin"
  }

  @doc """
  scope 层级判别的角色词表镜像（#1085 评审 T9 / T4b）。判定真源仍在
  `Rbac.staff?/manage?` 内部，这里只是让 tool_scopes_test 用一份镜像源做单向
  守卫——防止 scope 层级忘记跟随 Rbac 收紧/放宽。返回 `Enum.sort` 结果与
  `Rbac.workspace_manage_roles/0`、`staff_roles/0` 对齐比较。
  """
  @spec scope_role_names() :: [atom()]
  def scope_role_names, do: Enum.sort([:owner, :admin])

  @spec scope_tutor_role_names() :: [atom()]
  def scope_tutor_role_names, do: Enum.sort([:tutor, :owner, :admin])

  @doc """
  调用者当前持有的 scope 列表（空 = 只见全员可见名单）。fail-closed：读失败返回 []。

  跨工作台并集：任一工作台满足即算；平台管理员级联拿全部三个。
  """
  @spec granted(term()) :: [String.t()]
  def granted(nil), do: []

  def granted(actor) do
    case granted_or_error(actor) do
      {:ok, scopes} ->
        scopes

      {:error, error} ->
        # 错误文本经出口模块（error_egress_guard：MCP 树内不得直接 Exception.message；
        # 未映射的 DB 错误只出带 error id 的摘要，原文进服务端日志）
        Logger.error(
          "[Mcp.Scopes] membership read failed, granting no scopes: " <>
            Errors.message(error, "membership read failed")
        )

        []
    end
  end

  @doc false
  # Server 的 __before_compile__ 钩子：只拦 tools/list 与 tools/call，其余方法原样 super。
  #
  # tools/list：读失败用 internal_error 硬错误（评审 T1）——降级返回学员 32 子集会
  # 让 agent 长时间看到错名单且不自愈。scope 每请求重算，下一次 tools/list 即
  # 自愈（不需要重连）。tools/call：仍走 fail-closed 的 with_scopes——读失败
  # 只见 32，跨过这层还有 Wrapper 的 membership 门与工具层授权。
  defmacro __before_compile__(_env) do
    quote do
      @impl Anubis.Server
      def handle_request(%{"method" => "tools/list"} = request, frame) do
        case Cgc2046.Mcp.Scopes.granted_or_error(frame.assigns[:current_user]) do
          {:ok, scopes} ->
            claims = Anubis.Server.Authorization.normalize_claims(%{"scopes" => scopes})
            frame = put_in(frame.context.auth, claims)
            super(request, frame)

          {:error, error} ->
            require Logger

            Logger.error(
              "[Mcp.Scopes] tools/list scope computation failed: " <>
                Cgc2046.Mcp.Errors.message(error, "membership read failed")
            )

            {:error,
             Anubis.MCP.Error.protocol(:internal_error, %{
               message: "tool visibility temporarily unavailable; please try again"
             }), frame}
        end
      end

      def handle_request(%{"method" => "tools/call"} = request, frame) do
        frame = Cgc2046.Mcp.Scopes.with_scopes(frame)
        result = super(request, frame)
        Cgc2046.Mcp.Scopes.translate_denial(result, request)
      end

      def handle_request(request, frame), do: super(request, frame)
    end
  end

  @doc false
  # 把当前请求的 scope 注入 frame.context.auth（anubis 的 visible?/check_scopes 读它）。
  def with_scopes(frame) do
    scopes = granted(frame.assigns[:current_user])
    claims = Authorization.normalize_claims(%{"scopes" => scopes})

    put_in(frame.context.auth, claims)
  end

  @doc false
  # tools/list 专用：granted_or_error/1 让读取失败产生 internal_error 而不是静默降级
  # （评审 T1）。调用方（Server.handle_request/2 钩子）在 tools/list 路走这条；tools/call
  # 仍走 with_scopes/1 的 fail-closed 路径——scope 是粗检查，跨过它这层还有 Wrapper。
  @spec granted_or_error(term()) :: {:ok, [String.t()]} | {:error, Exception.t()}
  def granted_or_error(nil), do: {:ok, []}

  def granted_or_error(actor) do
    if PlatformAdmin.platform_admin?(actor) do
      {:ok, [@tutor, @workspace_admin, @platform_admin]}
    else
      {:ok, granted_for_roles(role_names!(actor))}
    end
  rescue
    error -> {:error, error}
  end

  # 判定的正典出口：granted/1（fail-closed）与 granted_or_error/1（透传）共用一个
  # 主体逻辑。授权规则本身不变。
  @spec granted_for_roles([atom()]) :: [String.t()]
  defp granted_for_roles(roles) do
    cond do
      Enum.any?(roles, &Role.manage_role?/1) -> [@tutor, @workspace_admin]
      :tutor in roles -> [@tutor]
      true -> []
    end
  end

  # 跨工作台角色名并集（成功路径）。失败会抛，由 granted_or_error/1 处理或
  # role_names/1 的 rescue 兜住。
  defp role_names!(actor) do
    actor
    |> MembershipContext.memberships_of_actor()
    |> Enum.flat_map(fn membership -> Enum.map(membership.roles, & &1.name) end)
  end

  @doc false
  # anubis 的 scope 拒绝（reason :execution_error + data 双键 required/granted）→
  # forbidden: 文案 + 补写审计。判据用 data shape 而非 message 字符串——anubis
  # 升级可能改 message 字面量或拆成 atom；双键 shape 是协议契约。data 不外发
  # （不泄露 granted 的 scope 命名）。
  def translate_denial(
        {:error, %Error{reason: :execution_error, data: %{required: required, granted: _granted}},
         frame},
        %{"method" => "tools/call", "params" => params}
      ) do
    tool = params["name"]
    needs = required |> Enum.map_join(" or ", &Map.get(@role_phrases, &1, &1))
    message = "forbidden: #{tool} requires #{needs}"

    Wrapper.record_denied(frame, tool, params["arguments"], message)

    {:error, Error.execution(message), frame}
  end

  def translate_denial(result, _request), do: result
end

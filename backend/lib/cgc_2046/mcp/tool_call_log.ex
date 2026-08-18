defmodule Cgc2046.Mcp.ToolCallLog do
  @moduledoc """
  MCP 工具调用审计资源（D9 / D-D8）。

  每次 MCP 工具调用落一行：谁 / 工具 / 参数（redact 后）/ 结果状态 / 耗时 /
  关联 pending_id（确认流）/ 宿主 client_name + 会话 session_id（#228 归因维度，
  多宿主 BYO 下「哪条调用来自哪个宿主 / 哪个会话」；流水维度不记则历史不可回填）。
  由服务端自动生成，不做用户侧上报（D9）。

  全局资源（不落 workspace_id 字段——params 内含，便于切片 F 审计聚合查询；
  params 落库前经 `Cgc2046.Mcp.Redact` 过滤 token/secret 等敏感键）。

  写入路径：tool wrapper 统一落库，policy 放行系统写（authorize?: false 调用）；
  读路径：platform_admin 可读全部（R10/R12，/admin/audit 页 + AshAdmin）；非 admin 仍 default-deny。
  """
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAdmin.Resource],
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Mcp

  attributes do
    uuid_primary_key(:id)

    attribute(:user_id, :uuid,
      allow_nil?: false,
      public?: true,
      description: "调用者（全局用户）ID"
    )

    attribute(:tool, :string,
      allow_nil?: false,
      public?: true,
      description: "工具名（如 get_workspace_context）"
    )

    attribute(:params, :map,
      allow_nil?: false,
      default: %{},
      public?: true,
      description: "调用参数（redact 后）"
    )

    attribute(:result_status, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:ok, :error, :needs_confirmation, :forbidden]],
      description: "调用结果状态"
    )

    attribute(:error_message, :string,
      allow_nil?: true,
      public?: true,
      description: "错误摘要（仅 error/forbidden 时有值，截断 500 字符）"
    )

    attribute(:latency_ms, :integer,
      allow_nil?: true,
      public?: true,
      description: "执行耗时（毫秒）"
    )

    attribute(:pending_operation_id, :uuid,
      allow_nil?: true,
      public?: true,
      description: "关联的确认流 pending 操作（needs_confirmation 时）"
    )

    attribute(:client_name, :string,
      allow_nil?: true,
      public?: true,
      description:
        "宿主客户端名（initialize clientInfo.name，如 openclacky/omp/opencode/dsh）#228 归因维度；取不到或历史行为 nil"
    )

    attribute(:session_id, :string,
      allow_nil?: true,
      public?: true,
      description: "MCP 会话 id（HTTP 为 Mcp-Session-Id，stdio 恒为 \"stdio\"）#228 归因维度；取不到或历史行为 nil"
    )

    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to(:user, Cgc2046.Accounts.User, define_attribute?: false)
  end

  postgres do
    table("mcp_tool_call_logs")
    repo(Cgc2046.Repo)
  end

  actions do
    default_accept([])
    defaults([:read])

    create :log do
      description("落一条工具调用审计（系统内部使用，bypass policy 调用）")

      accept([
        :user_id,
        :tool,
        :params,
        :result_status,
        :error_message,
        :latency_ms,
        :pending_operation_id,
        :client_name,
        :session_id
      ])
    end
  end

  policies do
    # 系统写入：tool wrapper 以 authorize?: false 调用；actor 直读留待切片 F 审计页
    policy action(:log) do
      authorize_if(always())
    end

    # platform_admin 可读全部审计记录（R10/R12 前置）；非 admin 仍 default-deny
    policy action_type(:read) do
      authorize_if(Cgc2046.Policies.PlatformAdmin)
    end
  end

  admin do
    # #113 ops 面优化：导航分组 + 列表列裁剪（默认全列横向爆炸；敏感/超大字段不列出）
    resource_group(:mcp)
    table_columns([:id, :user_id, :tool, :result_status, :latency_ms, :inserted_at])
  end
end

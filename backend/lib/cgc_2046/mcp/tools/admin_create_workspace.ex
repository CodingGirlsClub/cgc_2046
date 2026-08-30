defmodule Cgc2046.Mcp.Tools.AdminCreateWorkspace do
  @moduledoc """
  平台治理：创建工作台并指定 Owner（role-agent-journeys-v2 S2，
  确认流 two-tool 写，D-D3）。

  语义对齐 GraphQL `createWorkspace`（同 `Workspace :create` action）：
  自动 seed 五角色差异标签；Owner 指定二选一——

  - `owner_user_id`：现有用户直接入座 Owner membership；
  - `owner_email`：创建 preauthorized [:owner] 的 pending-owner 邀请
    （7 天有效），明文邀请 token 仅在 confirm 结果中一次性返回（不落库），
    由管理员带外交付给目标邮箱。

  第一次调用：不落业务库，建 PendingOperation，返回 needs_confirmation。
  confirm 后 `execute_confirmed/2` 真正创建（create policy 仅
  platform_admin；治理留痕 workspace_create 同事务落库）。

  授权 = Wrapper `:platform_admin` 门控族（第一段快速拒绝省 pending）；
  confirm 段由 create action 的 `Policies.PlatformAdmin` policy 兜底。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Accounts.{User, Workspace}
  alias Cgc2046.Mcp.Confirmation
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:name, {:required, :string}, description: "工作台名称")

    field(:slug, :string, description: "全局唯一 slug（小写字母/数字/连字符；缺省由名称派生，非 ASCII 名称回退随机 ws- 前缀）")

    field(:owner_user_id, :string, description: "指定已有用户为 Owner（用户 ID；与 owner_email 二选一）")

    field(:owner_email, :string,
      description: "邀请新用户为 Owner（邮箱，发 pending-owner 邀请；与 owner_user_id 二选一）"
    )
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_create_workspace", fn actor, _workspace_id, params ->
        name = params["name"] || params[:name]
        slug = params["slug"] || params[:slug] || default_slug(name)
        owner_user_id = params["owner_user_id"] || params[:owner_user_id]
        owner_email = params["owner_email"] || params[:owner_email]

        with :ok <- validate_owner_designation(owner_user_id, owner_email),
             {:ok, owner_summary} <- owner_summary(actor, owner_user_id, owner_email) do
          summary = "创建工作台「#{name}」（slug #{slug}）并指定 Owner：#{owner_summary}"

          Confirmation.request(
            frame.assigns[:current_user],
            "admin_create_workspace",
            params_with_slug(params, slug),
            summary
          )
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  @doc """
  确认后真正执行（由 `Confirmation.execute/3` 直接分派调用）。
  params 为 pending 落库的 redact 后参数（本工具参数无敏感键，直接可用）。
  """
  @spec execute_confirmed(term(), map()) :: {:ok, map()} | {:error, String.t()}
  def execute_confirmed(actor, params) do
    input =
      %{
        name: params["name"],
        slug: params["slug"],
        owner_user_id: params["owner_user_id"],
        owner_email: params["owner_email"]
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Workspace
         |> Ash.Changeset.for_create(:create, input)
         |> Ash.create(actor: actor) do
      {:ok, workspace} ->
        {:ok,
         %{
           workspace_id: workspace.id,
           name: workspace.name,
           slug: workspace.slug,
           join_policy: to_string(workspace.join_policy),
           owner_user_id: params["owner_user_id"],
           owner_email: params["owner_email"],
           # pending-owner 邀请明文 token 仅此处一次性返回（不落库）；
           # 客户端应展示给管理员带外交付后丢弃（owner_user_id 路径为 nil）
           owner_invitation_token: workspace.__metadata__[:owner_invitation_token]
         }}

      {:error, %Ash.Error.Forbidden{}} ->
        {:error, "forbidden: platform admin required to create workspaces"}

      {:error, %Ash.Error.Invalid{} = err} ->
        {:error, Exception.message(err)}

      {:error, _} ->
        {:error, "failed to create workspace"}
    end
  end

  defp validate_owner_designation(nil, nil),
    do: {:error, "invalid owner designation: owner_user_id 与 owner_email 必须提供其一"}

  defp validate_owner_designation(user_id, email) when not is_nil(user_id) and not is_nil(email),
    do: {:error, "invalid owner designation: owner_user_id 与 owner_email 只能提供一个"}

  defp validate_owner_designation(_user_id, _email), do: :ok

  # owner_user_id 路径顺带验证用户存在（不存在则快速失败，不建 pending）；
  # owner_email 路径目标尚非用户，直接回显邮箱
  defp owner_summary(actor, owner_user_id, nil) do
    case Ash.get(User, owner_user_id, actor: actor) do
      {:ok, nil} ->
        {:error, "owner user not found: #{owner_user_id}"}

      {:ok, user} ->
        {:ok, "用户 #{user.email && to_string(user.email)}（#{user.id}）直接入座"}

      {:error, _} ->
        {:error, "failed to load owner user"}
    end
  end

  defp owner_summary(_actor, nil, owner_email),
    do: {:ok, "发 pending-owner 邀请至 #{owner_email}（7 天有效，token 确认后一次性返回）"}

  # slug 缺省派生：名称小写化、非 [a-z0-9] 折叠为连字符；空结果（纯中文名等）
  # 回退随机 slug。派生结果与显式传入同走 domain 的格式/唯一校验（confirm 段兜底）
  defp default_slug(name) when is_binary(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if slug == "", do: random_slug(), else: slug
  end

  defp default_slug(_name), do: random_slug()

  defp random_slug, do: "ws-#{Ecto.UUID.generate() |> String.slice(0, 8)}"

  # 派生 slug 写回 pending params：confirm 段以 params["slug"] 为准，两段同一值
  defp params_with_slug(params, slug) do
    params
    |> Map.delete(:slug)
    |> Map.put("slug", slug)
  end
end

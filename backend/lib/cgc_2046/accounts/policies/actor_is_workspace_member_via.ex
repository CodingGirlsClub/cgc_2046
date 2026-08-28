defmodule Cgc2046.Accounts.Policies.ActorIsWorkspaceMemberVia do
  @moduledoc """
  「成员可读」授权的命名 FilterCheck：actor 是否为记录所属工作台的成员。

  这是「成员可读」的唯一声明入口，取代手写
  `authorize_if(relates_to_actor_via(<全路径>))`。各资源只声明怎么到工作台：

      policy action_type(:read) do
        authorize_if({Cgc2046.Accounts.Policies.ActorIsWorkspaceMemberVia, path: [:definition, :workspace]})
      end

  - `path`（atom 列表）：从当前资源到 `Cgc2046.Accounts.Workspace` 的关系路径
    **前缀**，语义是「怎么到 workspace」，而不是 Ash 关系路径的完整展开；
    Workspace 自身传 `[]`。
  - 成员尾巴 `[:memberships, :user]` 由本模块统一拼接——接口上写不出不完整
    的成员路径。

  ## #66 陷阱与硬校验

  `relates_to_actor_via` 取路径最后一个关系的 destination 主键生成
  `exists(path, pkey == actor.id)`；路径写不全（如只写 `[:memberships]`）不报错，
  静默生成 `membership.id == actor.id` 错语义（#66 review 发现，化石注释见
  `Cgc2046.Accounts.Workspace` invite_only policy）。本模块用硬校验替代该注释
  化石，构造 filter 时逐跳验证：

  - `path` 每跳必须是当前资源上存在的关系（`Ash.Resource.Info.relationship/2`）；
  - `path` 终点必须正是 `Cgc2046.Accounts.Workspace`；
  - Workspace 必须有 `:memberships` 关系，其 destination 必须有 `:user` 关系。

  任一不满足当场 `raise ArgumentError`，消息写明资源名、path 与出错跳。

  ## 下推

  filter/3 拼好全路径后委托 `Ash.Policy.Check.RelatesToActorVia.filter/3`
  （Ash 官方实现），AshPostgres 下推为 SQL EXISTS——下推逻辑零重写。
  reject 用 FilterCheck 默认实现 `[not: filter]`——成员尾巴的 memberships
  恒为 has_many，该默认与官方 reject/3 在此路径下恒等，不覆写以消除隐式依赖。
  """

  use Ash.Policy.FilterCheck

  alias Ash.Policy.Check.RelatesToActorVia
  alias Ash.Resource.Info

  @workspace Cgc2046.Accounts.Workspace
  @membership_tail [:memberships, :user]

  @impl true
  def describe(opts) do
    case Keyword.get(opts, :path, []) do
      [] -> "actor is a member of the workspace itself"
      path -> "actor is a member of the workspace via #{Enum.join(path, ".")}"
    end
  end

  @impl true
  def filter(actor, context, opts) do
    RelatesToActorVia.filter(actor, context,
      relationship_path: full_path!(resource!(context), opts)
    )
  end

  # context 缺 :resource 时与硬校验同走 ArgumentError（运行时 Ash 契约必传，
  # 仅手工构造 context 的测试/异常路径触发），fail-closed。
  defp resource!(context) do
    case Map.get(context, :resource) do
      nil ->
        raise ArgumentError,
              "#{inspect(__MODULE__)} 需要 context.resource，得到: #{inspect(context)}"

      resource ->
        resource
    end
  end

  # 硬校验并拼全路径：逐跳验证 path 关系存在、终点必须正是 Workspace、
  # 成员尾巴关系链完整；任一不满足 raise ArgumentError（替代 #66 静默错语义）。
  defp full_path!(resource, opts) do
    path = validate_path_shape!(resource, opts)
    destination = walk_path!(resource, opts, path)

    if destination != @workspace do
      raise ArgumentError,
            invalid_path_message(
              resource,
              opts,
              "path 终点必须是 #{inspect(@workspace)}，实际停在 #{inspect(destination)}"
            )
    end

    validate_membership_tail!(resource, opts)

    path ++ @membership_tail
  end

  defp validate_path_shape!(resource, opts) do
    case Keyword.get(opts, :path) do
      path when is_list(path) ->
        if Enum.all?(path, &is_atom/1) do
          path
        else
          raise ArgumentError,
                invalid_path_message(resource, opts, "path 必须全为 atom，得到: #{inspect(path)}")
        end

      other ->
        raise ArgumentError,
              invalid_path_message(resource, opts, "缺少 :path 选项或不是 atom 列表，得到: #{inspect(other)}")
    end
  end

  defp walk_path!(resource, opts, path) do
    Enum.reduce(path, resource, fn hop, current ->
      case Info.relationship(current, hop) do
        nil ->
          raise ArgumentError,
                invalid_path_message(resource, opts, "关系 :#{hop} 在 #{inspect(current)} 上不存在")

        rel ->
          rel.destination
      end
    end)
  end

  defp validate_membership_tail!(resource, opts) do
    case Info.relationship(@workspace, :memberships) do
      nil ->
        raise ArgumentError,
              invalid_path_message(resource, opts, "#{inspect(@workspace)} 缺少 :memberships 关系")

      memberships_rel ->
        destination = memberships_rel.destination

        if Info.relationship(destination, :user) == nil do
          raise ArgumentError,
                invalid_path_message(resource, opts, "#{inspect(destination)} 缺少 :user 关系")
        end

        :ok
    end
  end

  defp invalid_path_message(resource, opts, reason) do
    """
    #{inspect(__MODULE__)} 路径校验失败：#{reason}

    资源: #{inspect(resource)}
    path: #{inspect(Keyword.get(opts, :path))}

    path 语义是「从 #{inspect(resource)} 怎么到 #{inspect(@workspace)}」的关系路径前缀，
    成员尾巴 #{inspect(@membership_tail)} 由本模块统一拼接。
    """
  end
end

defmodule Cgc2046Web.GraphqlSchema.Recruitment.Helpers do
  @moduledoc """
  招募域 resolver helper（管理面门控、写路径与详情投影），仅供 `GraphqlSchema.Recruitment` 使用。
  """

  import Cgc2046Web.GraphqlSchema.Helpers
  require Ash.Query

  # --- Recruitment（Hacker Start 1024 campaign）resolver helpers -----------------

  # Owner/Admin 门控（KTD2 / KTD8 管理面边界）+ platform_admin 穿透，形状同 with_admin。
  #
  # 管理面入口为什么显式门控而不是只靠 read policy：VolunteerApplication /
  # ResumeProfile 的 read policy 含 `authorize_if(expr(user_id == ^actor(:id)))`
  # 这类**可下推为过滤**的检查——非管理角色调用时 Ash 退化成「只见自己的行」
  # 而不是 Forbidden（cohort 的匿名读也正是靠同一语义只见 open）。R13 管理面
  # 契约要的是非本台管理角色明确 forbidden（而非静默空集），故入口先判定；
  # 资源 policy 仍是第二层（platform_admin 穿透两处一致）。
  def with_workspace_manager(context, workspace_id, fun) do
    with_actor(context, fn actor ->
      cond do
        Cgc2046.Accounts.Policies.PlatformAdmin.platform_admin?(actor) -> fun.(actor)
        Cgc2046.Accounts.Rbac.manage?(actor, workspace_id) -> fun.(actor)
        true -> {:error, [message: "forbidden", code: "forbidden"]}
      end
    end)
  end

  # R13 列表按批次过滤（nil = 不过滤）；职位/段位过滤复用 AdminList.maybe_status_filter
  # （field 参数化 + 非枚举值静默忽略，与该组合子既有语义一致）。
  def maybe_cohort_filter(query, nil), do: query

  def maybe_cohort_filter(query, cohort_id),
    do: Ash.Query.filter(query, cohort_id == ^cohort_id)

  # Ash 写结果 → payload（result + errors）：业务错误进 payload errors（稳定 code），
  # 不落顶层 error——与自动生成 mutation 的错误协议一致（前端单一路径按 code 查文案）。
  #
  # `{:ok, nil}` 子句必须排在通用 `{:ok, record}` 之前：不静默当成功（result 与
  # errors 双空会让前端无法区分「无记录」与「操作成功」）。定位型 helper 已显式
  # 处理，此处是兜底。
  def recruitment_mutation_result({:ok, nil}, context, action, resource),
    do:
      recruitment_mutation_result(
        {:error, recruitment_not_found_error(nil, resource)},
        context,
        action,
        resource
      )

  def recruitment_mutation_result({:ok, record}, _context, _action, _resource),
    do: {:ok, %{result: record, errors: []}}

  def recruitment_mutation_result({:error, error}, context, action, resource),
    do:
      {:ok,
       %{
         result: nil,
         errors: mutation_errors(error, context, action, resource, Cgc2046.Recruitment)
       }}

  # 段位流转（advance_to_interview / advance_to_training / assign / reject / cancel）
  # 的 resolver 工厂：管理面门控 → tenant 内定位（授权读）→ for_update(action, args)。
  # 段位合法性（初始段位 CAS）与拒绝原因必填单源在域层，非法流转落稳定 code。
  def recruitment_stage_transition(action) do
    fn _, args, %{context: context} ->
      with_workspace_manager(context, args[:workspace_id], fn actor ->
        resource = Cgc2046.Recruitment.VolunteerApplication

        # 只透传本 action 声明的参数：Absinthe 的 args 已按声明过滤键，nil 值不进 attrs
        attrs =
          args
          |> Map.take([:assigned_event_id, :assignment_note, :reason])
          |> Enum.reject(fn {_key, value} -> is_nil(value) end)
          |> Map.new()

        with {:ok, %Cgc2046.Recruitment.VolunteerApplication{} = application} <-
               Ash.get(resource, args[:id], tenant: args[:workspace_id], actor: actor) do
          application
          |> Ash.Changeset.for_update(action, attrs,
            tenant: args[:workspace_id],
            actor: actor
          )
          |> Ash.update(tenant: args[:workspace_id], actor: actor)
          |> recruitment_mutation_result(context, action, resource)
        else
          {:ok, nil} ->
            recruitment_mutation_result(
              {:error, recruitment_not_found_error(args[:id], resource)},
              context,
              action,
              resource
            )

          {:error, error} ->
            recruitment_mutation_result({:error, error}, context, action, resource)
        end
      end)
    end
  end

  # 批次状态迁移（open / close）resolver 工厂：形状同段位流转（唯一 open 冲突与
  # 状态迁移的 DB 部分唯一索引错误都在域层 action 上，落稳定 code）。
  def recruitment_cohort_status_mutation(action) do
    fn _, args, %{context: context} ->
      with_workspace_manager(context, args[:workspace_id], fn actor ->
        resource = Cgc2046.Recruitment.RecruitmentCohort

        recruitment_cohort_update(args[:workspace_id], args[:id], action, %{}, actor)
        |> recruitment_mutation_result(context, action, resource)
      end)
    end
  end

  # 批次定位（tenant 内授权读）+ 更新/迁移：id 不存在或跨台 → not_found
  # （与自动 mutation 的 NotFound 映射同形，不泄露存在性），不静默成功。
  def recruitment_cohort_update(workspace_id, id, action, attrs, actor) do
    resource = Cgc2046.Recruitment.RecruitmentCohort

    case Ash.get(resource, id, tenant: workspace_id, actor: actor) do
      {:ok, %Cgc2046.Recruitment.RecruitmentCohort{} = cohort} ->
        cohort
        |> Ash.Changeset.for_update(action, attrs, tenant: workspace_id, actor: actor)
        |> Ash.update(tenant: workspace_id, actor: actor)

      {:ok, nil} ->
        {:error, recruitment_not_found_error(id, resource)}

      {:error, error} ->
        {:error, error}
    end
  end

  def recruitment_not_found_error(id, resource),
    do: Ash.Error.Query.NotFound.exception(primary_key: %{id: id}, resource: resource)

  # R13 申请详情：tenant 内取申请（owner 视图读全量），再按申请人取简历档案
  # （同 tenant；Owner/Admin ∪ platform_admin 可读）。无档案 → resumeProfile null；
  # 文件内容列不出面（KTD3，U2 专线）。
  def resolve_volunteer_application_detail(workspace_id, id, actor, context) do
    case Ash.get(Cgc2046.Recruitment.VolunteerApplication, id,
           tenant: workspace_id,
           actor: actor
         ) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, %Cgc2046.Recruitment.VolunteerApplication{} = application} ->
        case fetch_resume_profile(workspace_id, application.user_id, actor) do
          {:ok, profile} ->
            {:ok, %{application: application, resume_profile: profile}}

          {:error, error} ->
            {:error,
             to_ash_graphql_errors(
               error,
               context,
               :read,
               Cgc2046.Recruitment.ResumeProfile,
               Cgc2046.Recruitment
             )}
        end

      {:error, error} ->
        {:error,
         to_ash_graphql_errors(
           error,
           context,
           :read,
           Cgc2046.Recruitment.VolunteerApplication,
           Cgc2046.Recruitment
         )}
    end
  end

  def fetch_resume_profile(workspace_id, user_id, actor) do
    Cgc2046.Recruitment.ResumeProfile
    |> Ash.Query.for_read(:read)
    # 同 my_resume_profile：详情投影只用元数据，不拖 file_data blob
    |> Ash.Query.deselect(:file_data)
    |> Ash.Query.filter(user_id == ^user_id)
    |> Ash.read_one(tenant: workspace_id, actor: actor)
  end
end

defmodule Cgc2046.Curriculum do
  @moduledoc """
  教研域（ADR-0009 PR③）：教研产出物（Output = 课程内容唯一持久层）与
  教研 run 生命周期（Instantiator 实例化 / Reaper 回收）。内容读契约归本域
  （KD3：内容写侧是教研产出，写作权不能错配给消费方），Course 持委托。

  KTD1 域纪律：与 Cgc2046.Payments / Cgc2046.Admission 同款——
  `graphql do authorize?(true) end`，未带 policy 的动作默认拒绝，防止意外公开
  租户资源。
  """

  use Ash.Domain,
    otp_app: :cgc_2046,
    extensions: [AshGraphql.Domain, AshAdmin.Domain]

  require Ash.Query

  admin do
    # 安全门控由 :admin_browser pipeline 的 PlatformAdminPlug 承担（各 domain 同款）
    show?(true)
    # #113 ops 面优化同款：domain 命名 + 资源分组标签（中文）
    name("Curriculum")
    resource_group_labels(curriculum: "教研")
  end

  graphql do
    authorize?(true)
  end

  resources do
    # ADR-0009 R4：Output（原 Workflows.ResearchOutput）归 Curriculum context
    resource(Cgc2046.Curriculum.Output)
  end

  # ── 内容读契约（KD3/R4）：唯一实现落本域；MCP 工具与 GraphQL resolver 直调（Course 侧零调用兼容委托已删，Fable 5 LOW）──

  # 地图行(goal-only,R10):key 派生(KTD6)= slug 短码 + 卡集内 1 起序号。
  # 消费方 = graphql_schema resolve_course_map(G3:calculate 包装已删,
  # 无 GraphQL/Ash 面需要,留纯函数直调)
  @doc false
  def issue_map_rows(%Cgc2046.Courses.Course{} = course) do
    content = course_content(course)

    content
    |> Cgc2046.Curriculum.Content.issues()
    |> Enum.with_index(1)
    |> Enum.map(fn {issue, idx} ->
      %{
        key: Cgc2046.Learning.Progress.issue_key(course.slug, idx),
        id: issue["id"],
        title: issue["title"],
        kind: issue["kind"],
        goal: issue["story"]["goal"]
      }
    end)
  end

  # U7:课程内容读取(公开地图与学员详情共用源);authorize?: false——门禁在
  # 调用面(course 读 policy / 学习详情工具层授权),内容本体无独立敏感面
  # (goal-only 投影由调用方负责;本函数返回全量 content,不外泄 checklist 的
  # 责任在投影层)。
  def course_content(%Cgc2046.Courses.Course{id: id, workspace_id: workspace_id})
      when is_binary(id) and is_binary(workspace_id) do
    case content_output(workspace_id, id) do
      {:ok, output} -> output && output.data
      _ -> nil
    end
  end

  def course_content(_course), do: nil

  # A4 收敛:课程内容 Output(kind=:issues, key=course_<id>)单一读入口——
  # curriculum_progress_worker / learning_progress_worker / mcp get_course_content /
  # graphql_schema 原五处同形查询的唯一真源。authorize?: false 语义同
  # course_content/1 头注(门禁在调用面);返回原始 Output 记录,
  # 投影(data 解包)与错误形状由各调用方自持。
  @spec content_output(String.t(), String.t()) ::
          {:ok, Cgc2046.Curriculum.Output.t() | nil} | {:error, term()}
  def content_output(workspace_id, course_id)
      when is_binary(workspace_id) and is_binary(course_id) do
    Cgc2046.Curriculum.Output
    |> Ash.Query.filter(
      key == ^Cgc2046.Curriculum.Output.course_key(course_id) and kind == :issues
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false, tenant: workspace_id)
  end
end

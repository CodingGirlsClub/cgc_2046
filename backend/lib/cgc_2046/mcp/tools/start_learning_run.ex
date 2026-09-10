defmodule Cgc2046.Mcp.Tools.StartLearningRun do
  @moduledoc """
  启动(或幂等续学)学员对课程当前 published revision 的学习 run
  (role-agent-journeys-v2 S8,R36)。

  实例 key = `Cgc2046.Learning.Runs.instance_key/2`(issue #505 D8:
  `"learning_<user_id>_<revision_id>"`,key 仅为可读标签)。去重真源 =
  user × revision **非终态**预查 + DB partial unique index:命中已有
  非终态 run 返回 `created: false`(resume);终态后可重学(新版发布
  或重学场景自动开新 run)。

  授权(`membership: :deferred`,工具层判定):本人 confirmed enrollment
  的学员可启动——课程 confirmed 报名 ∨ 挂载授权(锚定本课程 revision
  的活动的 confirmed 报名,D9);成员不代学员启动;tutor 的教学面走
  get_learning_state / GraphQL。启动要求课程已有 published revision
  (无 → 明确错误,教研未完成),且租户内有 published `type=learning` 定义。

  判定与效应单源 = `Cgc2046.Learning.Runs.start/3`(enrollment.completed
  异步实例化 `LearningInstantiator` 与本工具在 user × revision 维度汇流,
  双通道报名汇入同一活跃 run)。
  """
  use Anubis.Server.Component, type: :tool, meta: %{membership: :deferred}

  alias Cgc2046.Learning.Runs
  alias Cgc2046.Mcp.Tools.Response
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID(UUID)")
    field(:course_id, {:required, :string}, description: "课程 ID(UUID)")
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "start_learning_run", fn actor, workspace_id, params ->
        course_id = params["course_id"]

        case Runs.start(actor, workspace_id, course_id) do
          {:ok, run, created_or_existing} ->
            {:ok, revision} = Runs.revision_of(run)
            revision_id = revision && revision.id

            {:ok,
             %{
               run_id: run.id,
               revision_id: revision_id,
               revision_number: revision && revision.number,
               status: to_string(run.status),
               created: created_or_existing == :created
             }}

          {:error, message} ->
            {:error, message}
        end
      end)

    Response.to_response(result, frame)
  end
end

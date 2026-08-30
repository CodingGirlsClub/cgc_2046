defmodule Cgc2046.Mcp.Tools.StartLearningRun do
  @moduledoc """
  启动(或幂等续学)学员对课程当前 published revision 的学习 run
  (role-agent-journeys-v2 S8,R36)。

  语义:一个报名对一个课程版本 = 一个 learning run(`Runs.instance_key/2`
  = `"learning_<enrollment_id>_<revision_id>"`)。命中已有 run(**任意状态**,
  含终态)即返回 `created: false`——同版重进是 resume;想学新版等发布新
  revision 后再调(key 变化自动开新 run)。

  授权(`membership: :deferred`,工具层判定):仅本人 confirmed enrollment
  的学员可启动(成员不代学员启动;tutor 的教学面走 get_learning_state /
  GraphQL)。启动要求课程已有 published revision(无 → 明确错误,教研未
  完成),且租户内有 published `type=learning` 定义。

  判定与效应单源 = `Cgc2046.Learning.Runs.start/3`(enrollment.completed
  异步实例化 `LearningInstantiator` 与本工具共用同一 key,两路径幂等互通)。
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
        course_id = params["course_id"] || params[:course_id]

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

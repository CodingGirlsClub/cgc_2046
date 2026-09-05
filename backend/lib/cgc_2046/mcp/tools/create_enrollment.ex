defmodule Cgc2046.Mcp.Tools.CreateEnrollment do
  @moduledoc """
  学员报名（role-agent-journeys-v2 S7，R31/AE3；直接写——客户端确认
  即契约，不进 D-D3 确认流）。

  委派域 action `Enrollment :create_enrollment`（与 web/小程序同源同语义）：
  reason 经域内内容安全检查（msgSecCheck）；收费供给 tier_id 必填（域强校验，
  本工具不预检）；open 立即占位、request 落 pending 待审批；收费占位后落
  payment_pending。workspace_id 必须与目标供给所属工作台一致（域
  resolve_tenant 防跨工作台越权）。

  **幂等重放（TD8）**：域 create 撞活跃报名唯一不变量（部分唯一索引，
  BusinessError code `enrollment_duplicate_active`）时，加载 actor 的既有活跃
  报名并原样返回 + `idempotent_replay: true`（**不是错误**）——客户端重试/
  双击/网络重放安全。并发双建由 DB 唯一索引裁决：后到者必走重放路径，
  全系统恰好一条活跃报名。

  `checkout_url` 仅当报名落 `payment_pending` 时给出（web 下单页
  `/orders/new?enrollmentId=`，外部浏览器完成支付；LearnerJourney.checkout_url/1）。
  域错误（内容违规 / 名额已满 / 截止已过 / 需邀请码）原样透传既有消息，
  不发明新 coded error。

  **审计红线**：reason 自由文本不进 Wrapper 审计——进 `Wrapper.run` 前从
  params 摘除（ToolCallLog.params 永不落用户内容文本，与域「违规内容不落库」
  同纪律），经闭包传给业务 fun。
  """
  use Anubis.Server.Component, type: :tool, meta: %{membership: :deferred}

  alias Cgc2046.Admission.Enrollment
  alias Cgc2046.Mcp.Tools.LearnerJourney
  alias Cgc2046.Mcp.Wrapper

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID，须与供给所属工作台一致）")
    field(:kind, {:required, :string}, description: "event | course")

    field(:offering_id, {:required, :string},
      description: "活动或课程 ID（UUID，来自 discover_offerings 条目 id）"
    )

    field(:reason, :string, description: "报名理由（可选自由文本，≤2500 字节；过平台内容安全检查，违规拒绝不落库）")

    field(:tier_id, :string,
      description: "价格档位 ID（收费供给必填，取自 get_enrollment_summary 的 price_tiers；免费供给忽略）"
    )
  end

  @impl true
  def execute(params, frame) do
    # reason 自由文本不落 ToolCallLog.params（审计红线）：摘除后经闭包传递。
    {reason, log_params} = pop_reason(params)

    result =
      Wrapper.run(frame, log_params, "create_enrollment", fn actor, workspace_id, params ->
        offering_id = params["offering_id"] || params[:offering_id]

        with {:ok, kind} <- LearnerJourney.parse_required_kind(params["kind"] || params[:kind]) do
          do_create(actor, workspace_id, kind, offering_id, params, reason)
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  defp pop_reason(params) do
    {Map.get(params, "reason") || Map.get(params, :reason),
     params |> Map.delete("reason") |> Map.delete(:reason)}
  end

  defp do_create(actor, workspace_id, kind, offering_id, params, reason) do
    tier_id = params["tier_id"] || params[:tier_id]
    target_key = if kind == :event, do: :event_id, else: :course_id

    attrs =
      %{user_id: actor.id, submission_payload: submission_payload(reason)}
      |> Map.put(target_key, offering_id)
      |> maybe_put(:tier_id, tier_id)

    case Enrollment
         |> Ash.Changeset.for_create(:create_enrollment, attrs)
         |> Ash.create(actor: actor, tenant: workspace_id) do
      {:ok, enrollment} ->
        {:ok, to_payload(enrollment, kind, false)}

      {:error, error} ->
        handle_create_error(error, actor, workspace_id, kind, offering_id)
    end
  end

  # 幂等重放（TD8 + #349 B）：活跃报名存在 → 重放优先于任何创建错误——
  # 唯一索引冲突（enrollment_duplicate_active）与前置校验失败（截止已过 /
  # 供给关闭 / 档位失效 / 名额占满——首次成功后重放会在 eligible_target /
  # reserve_capacity 先挡，到不了唯一索引）同权。回读按 (actor, kind,
  # offering, workspace) 四元组；未命中 → 原样透传域错误（content_rejected /
  # invite_code_required 等）。
  defp handle_create_error(error, actor, workspace_id, kind, offering_id) do
    case LearnerJourney.active_enrollment(actor, kind, offering_id, workspace_id) do
      nil -> domain_error(error, workspace_id)
      enrollment -> {:ok, to_payload(enrollment, kind, true)}
    end
  end

  defp domain_error(%Ash.Error.Forbidden{}, workspace_id),
    do: {:error, "forbidden: not allowed to enroll in workspace #{workspace_id}"}

  defp domain_error(%Ash.Error.Invalid{} = err, _workspace_id),
    do: {:error, Exception.message(err)}

  defp domain_error(_, _workspace_id), do: {:error, "failed to create enrollment"}

  # reason 自由文本进 submission_payload（域内容安全检查的唯一检查字段）；
  # 缺省 %{} = 无可查内容直通。
  defp submission_payload(reason) when is_binary(reason), do: %{"reason" => reason}
  defp submission_payload(_reason), do: %{}

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp to_payload(enrollment, kind, idempotent_replay) do
    %{
      enrollment: %{
        id: enrollment.id,
        status: to_string(enrollment.status),
        kind: to_string(kind),
        offering_id: offering_id_of(enrollment),
        workspace_id: enrollment.workspace_id
      },
      checkout_url: checkout_url(enrollment),
      idempotent_replay: idempotent_replay
    }
  end

  defp offering_id_of(%{event_id: event_id}) when is_binary(event_id), do: event_id
  defp offering_id_of(%{course_id: course_id}) when is_binary(course_id), do: course_id

  # 支付入口：仅 payment_pending 给下单页链接；其余状态无支付动作
  defp checkout_url(%{status: :payment_pending, id: id}), do: LearnerJourney.checkout_url(id)
  defp checkout_url(_enrollment), do: nil
end

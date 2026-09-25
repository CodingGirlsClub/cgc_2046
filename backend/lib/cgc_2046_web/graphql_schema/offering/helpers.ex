defmodule Cgc2046Web.GraphqlSchema.Offering.Helpers do
  @moduledoc """
  Offering 治理域域内 resolver helper：U2 读面行/详情投影、U1 治理写工厂、
  规则读写与核销押金退款侧事实；仅本域 notation 模块使用。
  """

  require Ash.Query
  require Logger

  import Cgc2046Web.GraphqlSchema.Helpers

  # ── U2 治理读面：offering（Event / Course）行与详情投影 ────────────────────
  # 行 = 列表用最小集（`admin_event` / `admin_course` 的字段全集，SDL 与投影
  # 一一对应）；详情 = 行 ⊕ 处置/排查字段。计数按场现取（KTD4），不入行投影。

  def admin_event_row(event) do
    %{
      id: event.id,
      workspace_id: event.workspace_id,
      title: event.title,
      slug: event.slug,
      status: to_string(event.status),
      visibility: to_string(event.visibility),
      capacity: event.capacity,
      registration_deadline: event.registration_deadline,
      starts_at: event.starts_at,
      ends_at: event.ends_at,
      pricing_enabled: event.pricing_enabled,
      deposit_enabled: event.deposit_enabled,
      deposit_amount_cents: event.deposit_amount_cents,
      inserted_at: event.inserted_at,
      updated_at: event.updated_at
    }
  end

  def admin_event_detail_row(event, actor) do
    Map.merge(admin_event_row(event), %{
      description: event.description,
      venue: event.venue,
      confirmed_count:
        offering_enrollment_count(:event_id, event.id, event.workspace_id, :confirmed),
      payment_pending_count:
        offering_enrollment_count(:event_id, event.id, event.workspace_id, :payment_pending),
      moderators: admin_event_moderators(event, actor),
      detached_rule_provenance: event.detached_rule_provenance
    })
  end

  # 主理人清单（U2）：走 `Moderators.list/3` 的读面（平台管理员分支已放行），
  # 不另起直读 EventModerator 的第二条读序；失败返回 nil（Logger 留痕）——
  # 附挂信息不阻断详情主读，且「空清单」与「清单加载失败」在 SDL 上可区分
  # （同 admin_initiative.mountedEvents 先例）。
  def admin_event_moderators(event, actor) do
    case Cgc2046.Events.Moderators.list(event.id, event.workspace_id, actor) do
      {:ok, rows} ->
        rows

      {:error, reason} ->
        Logger.error("[get_admin_event.moderators] load failed: #{inspect(reason)}")
        nil
    end
  end

  def admin_course_row(course) do
    %{
      id: course.id,
      workspace_id: course.workspace_id,
      title: course.title,
      provisional_title: course.provisional_title,
      slug: course.slug,
      status: to_string(course.status),
      visibility: to_string(course.visibility),
      capacity: course.capacity,
      registration_deadline: course.registration_deadline,
      starts_at: course.starts_at,
      ends_at: course.ends_at,
      pricing_enabled: course.pricing_enabled,
      inserted_at: course.inserted_at,
      updated_at: course.updated_at
    }
  end

  def admin_course_detail_row(course) do
    Map.merge(admin_course_row(course), %{
      description: course.description,
      current_revision_number: current_revision_number(course),
      confirmed_count:
        offering_enrollment_count(:course_id, course.id, course.workspace_id, :confirmed),
      payment_pending_count:
        offering_enrollment_count(:course_id, course.id, course.workspace_id, :payment_pending)
    })
  end

  # 当前修订号（计划 R3「Course 详情加当前 revision」）：按 current_revision_id
  # 现取 `CourseRevision.number`（不是 number 最大的行——可能存在已生成未绑定的
  # 更高号修订）。nil = 未绑定（draft 未发布常态）或现取失败；与 KTD4 同纪律，
  # 不伪造值。
  def current_revision_number(course) do
    with id when not is_nil(id) <- course.current_revision_id,
         {:ok, revision} <-
           Ash.get(Cgc2046.Curriculum.CourseRevision, id,
             authorize?: false,
             tenant: course.workspace_id
           ) do
      revision.number
    else
      _ -> nil
    end
  end

  # KTD4 权威报名计数：按 offering 现取 `Enrollment` 行数（`status` 分列），
  # **不读** `events.confirmed_count` / `courses.confirmed_count` 展示投影
  # （自述可能滞后一拍）。filter 形状与工作台侧批量免缴披露（update_event /
  # update_course 的 payment_pending_count）逐字同源——治理面披露的数字与
  # 写面 200 笔上限判定的数字必须来自同一口径。
  #
  # 查询失败返回 nil（= SDL 的 nil「计数不可用」），**不回退 0**：0 是「确实
  # 没有」的事实，不可用与 0 混同会让界面骗人（KTD4 不落假值）。
  def offering_enrollment_count(offering_field, offering_id, workspace_id, status) do
    Cgc2046.Admission.Enrollment
    |> Ash.Query.filter(^[{offering_field, offering_id}])
    |> Ash.Query.filter(status == ^status)
    |> Ash.count(authorize?: false, tenant: workspace_id)
    |> case do
      {:ok, count} ->
        count

      {:error, error} ->
        Logger.error(
          "[admin_offering_detail.enrollment_count] #{offering_field}/#{status} failed: " <>
            inspect(error)
        )

        nil
    end
  end

  # #596 挂载前预览：RulePreview 返回规则原始值（MCP 面直接用 map），GraphQL 面
  # 按既有 AdminInitiativeRule 口径转 value_json 字符串
  def initiative_mount_preview_row(preview) do
    %{
      initiative_id: preview.initiative_id,
      name: preview.name,
      slug: preview.slug,
      status: preview.status,
      rules:
        Enum.map(preview.rules, fn rule ->
          %{key: rule.key, value_json: Jason.encode!(rule.value), locked: rule.locked}
        end),
      missing_rules: preview.missing_rules
    }
  end

  # ── U1 治理写 resolver（Event / Course 共用同一对工厂）─────────────────────
  # with_admin 门控 → Ash.get（multitenant global 资源，无 tenant 跨租户定位）→
  # for_update + Ash.update（actor 直传、标准授权，无 authorize?: false 旁路）——
  # 与 initiative_status_mutation/1 同形：守卫/信号链/留痕全部由 action 本体承担。
  def offering_status_mutation(resource, action, domain) do
    fn _, %{id: id}, %{context: context} ->
      with_admin(context, fn actor ->
        with {:ok, offering} <- Ash.get(resource, id, actor: actor) do
          offering
          |> Ash.Changeset.for_update(action, %{})
          |> Ash.update(actor: actor)
          |> offering_mutation_result(resource, action, domain, context)
        else
          {:error, error} ->
            {:ok,
             %{result: nil, errors: mutation_errors(error, context, action, resource, domain)}}
        end
      end)
    end
  end

  def offering_update_mutation(resource, fields, domain) do
    fn _, %{id: id, input: input}, %{context: context} ->
      with_admin(context, fn actor ->
        with {:ok, offering} <- Ash.get(resource, id, actor: actor) do
          offering
          |> Ash.Changeset.for_update(:update, map_input(input, fields))
          |> Ash.update(actor: actor)
          |> offering_mutation_result(resource, :update, domain, context)
        else
          {:error, error} ->
            {:ok,
             %{result: nil, errors: mutation_errors(error, context, :update, resource, domain)}}
        end
      end)
    end
  end

  def offering_mutation_result({:ok, offering}, _resource, _action, _domain, _context),
    do: {:ok, %{result: offering, errors: []}}

  def offering_mutation_result({:error, error}, resource, action, domain, context) do
    {:ok, %{result: nil, errors: mutation_errors(error, context, action, resource, domain)}}
  end

  def decode_rule_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _} -> {:error, "rule value must be a JSON object"}
      {:error, _} -> {:error, "rule value_json must be valid JSON"}
    end
  end

  def get_initiative_rule(initiative_id, key, actor) do
    Cgc2046.Initiatives.InitiativeRule
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(initiative_id == ^initiative_id and key == ^key)
    |> Ash.read_one(actor: actor)
  end

  # key 白名单单源 = InitiativeRule.rule_keys()；未知 key → {:error, "invalid rule key"}
  # （else 分支映射为 code invalid_input 的 payload error），不做 String.to_existing_atom。
  def rule_key(key) when is_binary(key) do
    case Enum.find(Cgc2046.Initiatives.InitiativeRule.rule_keys(), &(Atom.to_string(&1) == key)) do
      nil -> {:error, "invalid rule key"}
      key_atom -> {:ok, key_atom}
    end
  end

  # admin 列表 read 结果 → map_error 后逐行过投影（治理读面的行投影出口）
  def admin_rows(resource, domain, row_fun) do
    fn result, context ->
      case map_error(result, context, :read, resource, domain) do
        {:ok, records} -> {:ok, Enum.map(records, row_fun)}
        {:error, _} = error -> error
      end
    end
  end

  # 核销结果里的押金退款侧事实（KTD6 分派表）：读该报名**唯一活跃押金单**的
  # 状态；无押金单 → nil（本次核销不产生退款）。单次点查（核销是低频人工动作）。
  def deposit_refund_state(enrollment_id) do
    case Cgc2046.Repo.query(
           """
           SELECT status FROM payments_orders
           WHERE enrollment_id = $1 AND order_kind = 'deposit'
             AND status IN ('paid', 'refunding', 'refunded', 'refund_failed', 'forfeited')
           ORDER BY inserted_at DESC LIMIT 1
           """,
           [Cgc2046.Repo.uuid!(enrollment_id)]
         ) do
      {:ok, %{rows: [[status]]}} ->
        case status do
          # 核销后仍是 paid 只可能是异常残留：不宣称已发起退款
          "paid" -> nil
          "refund_failed" -> "refunding"
          other -> other
        end

      _ ->
        nil
    end
  end
end

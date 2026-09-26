defmodule Cgc2046.Mcp.Tools.BatchCreateEvents do
  @moduledoc """
  批量创建活动草稿（#511）：单工作台一次建 N 场（上限 1024，Phase 2 规模），
  Owner/Admin 管理工具，直接写不进确认流（对齐 create_event 的 R12 先例——同语义
  操作不因数量变门：draft 可逆、可删（delete_event #676）、幂等可重放）。

  逐行独立提交 + 行级报告（#511 裁决）：draft 无对外副作用，部分成功无毒；
  行级错误给行号 + 字段 + 原因，失败行修正后原样重喂——成功行会被幂等跳过。

  幂等 = slug 即幂等键（零落库，不建批次表）：
  - 每行 slug 必填（确定性 slug 是批量场景硬需求；缺省随机 `e-<hex>` 会毁幂等，
    故本工具直接拒绝无 slug 行而非回退生成）；
  - 重放撞 `events_slug_index`（转 BusinessError `event_slug_taken`）后 read-back
    判归属：同工作台 → `skipped`（已存在，不更新——数据以首次为准）；异工作台 →
    行级失败（真冲突）。批内重复 slug 同语义（后行 read-back 到前行 → skipped）；
  - 「批次号 + 行号」由确定性 slug 承载（`1024-<city>-<NNN>` 之类命名模板归调用
    侧 / playbook 决定，本工具不发明领域命名逻辑）；批次可观察面 = slug 前缀 +
    ToolCallLog 审计行。

  与 create_event 的关系：行级字段白名单单源 `CreateEvent.create_fields/0`（多余
  键丢弃，不发明字段）；逐行走同一 `Events.Event :create` action（校验 / venue /
  定价押金互斥 / initiative 挂载继承全部同源生效）。

  响应省略 inherited（#511 裁决 D6）：101 行 × ~500B 无必要，继承细节用
  list_workspace_events 单场可查。行级只回 row/status/slug/title/event_id/error。

  审计退化为预期形态：Redact `@max_params_bytes`（8KB）之上整条 params 摘要化
  （metadata_only，保留 workspace_id 等查询锚）——大批量重放属正常调用形态，
  不是审计丢失；审计查询按 workspace_id 过滤不受影响。

  错误纪律（#680/#691）：行级错误复用既有 BusinessError code（变量透传，不新增
  码）与 Ash 校验叶子的 field + message 转译；工具级参数错误走 `"invalid: ..."`
  字符串（含行号），不碰 keyword 错误路径。

  Owner/Admin 专属：与 create_event 同门——member-only 默认门 + 工具层管理角色
  判定 + 业务 create action 的 `WorkspaceActorIsOwnerOrAdmin` policy 兜底。
  """

  use Anubis.Server.Component, type: :tool

  alias Cgc2046.Accounts.Rbac
  alias Cgc2046.Errors.BusinessError
  alias Cgc2046.Errors.DatabaseError
  alias Cgc2046.Events.Event
  alias Cgc2046.Mcp.Tools.CreateEvent
  alias Cgc2046.Mcp.Wrapper

  # Phase 2 规模上限（1024 场）；硬编码不配置化，改值需同步本 moduledoc 与
  # playbook 口径。
  @max_rows 1024

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    工作台 Owner/Admin 专用，直接写入，不走确认流：一次批量创建多场活动草稿（draft），最多 1024 行。
    每行字段同 create_event（多余字段丢弃），title 与 slug 必填：slug 全局唯一，同时是幂等键——重放
    同一批时，已存在于本工作台的 slug 返回 skipped（不更新，数据以首次为准），被其他工作台占用则该行
    失败。每行独立提交，部分失败不影响其他行；修正失败行后可以把整批原样重发。返回逐行结果
    row / status / slug / title / event_id / error（错误含字段与原因），不含挂载继承明细（需要时用
    list_workspace_events 查单场）。
    """
  end

  schema do
    field(:workspace_id, {:required, :string}, description: "目标工作台 ID（UUID）")

    field(:rows, {:required, {:list, :map}},
      description:
        "批量行（每行一个活动，字段同 create_event：title 必填、slug 必填且全局唯一" <>
          "（确定性 slug 是幂等键，如 1024-<city>-<NNN>）、starts_at/ends_at/venue/capacity/" <>
          "pricing/deposit/initiative_id 等；行数上限 #{@max_rows}；多余字段丢弃）"
    )
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "batch_create_events", fn actor, workspace_id, params ->
        rows = params["rows"]

        with :ok <- authorize(actor, workspace_id),
             :ok <- validate_rows(rows) do
          {:ok, run_batch(rows, workspace_id, actor)}
        end
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  # Owner/Admin 专属（与 create_event 同款 S3 门）：非管理角色成员快速拒绝
  defp authorize(actor, workspace_id) do
    if Rbac.manage?(actor, workspace_id) do
      :ok
    else
      {:error, "forbidden: owner or admin required to create events"}
    end
  end

  # ---- 参数级校验（fail-fast，不落库）----

  defp validate_rows(rows) when is_list(rows) do
    cond do
      rows == [] ->
        {:error, "invalid: rows must be a non-empty list"}

      length(rows) > @max_rows ->
        {:error, "invalid: rows count #{length(rows)} exceeds max #{@max_rows}"}

      true ->
        validate_each_row(rows, 1)
    end
  end

  defp validate_rows(_rows), do: {:error, "invalid: rows must be a list"}

  # 逐行校验通过即 :ok（行由外层 rows 原样进 run_batch——校验器只裁决，不重建列表）
  defp validate_each_row([], _idx), do: :ok

  defp validate_each_row([row | rest], idx) do
    cond do
      not is_map(row) ->
        {:error, "invalid: row #{idx} must be an object"}

      not (is_binary(row["slug"]) and row["slug"] != "") ->
        {:error,
         "invalid: row #{idx} requires a non-empty slug (deterministic slugs are the idempotency key, e.g. 1024-<city>-<NNN>)"}

      true ->
        validate_each_row(rest, idx + 1)
    end
  end

  # ---- 逐行执行（独立提交，无跨行事务）----

  defp run_batch(rows, workspace_id, actor) do
    results =
      rows
      |> Enum.with_index(1)
      |> Enum.map(fn {row, idx} -> create_row(row, idx, workspace_id, actor) end)

    counts = Enum.frequencies_by(results, & &1.status)

    %{
      summary: %{
        total: length(results),
        created: Map.get(counts, "created", 0),
        skipped: Map.get(counts, "skipped", 0),
        failed: Map.get(counts, "failed", 0)
      },
      rows: results
    }
  end

  defp create_row(row, idx, workspace_id, actor) do
    input = take_fields(row, CreateEvent.create_fields())

    case Event
         |> Ash.Changeset.for_create(:create, input, tenant: workspace_id)
         |> Ash.create(actor: actor, tenant: workspace_id) do
      {:ok, event} ->
        %{row: idx, status: "created", event_id: event.id, slug: event.slug, title: event.title}

      {:error, %Ash.Error.Forbidden{}} ->
        failed_row(row, idx, nil, %{
          message: "forbidden: not allowed to create event in workspace #{workspace_id}",
          fields: []
        })

      {:error, error} ->
        # 唯一索引冲突（domain error_handler 已转 BusinessError event_slug_taken）→
        # read-back 判归属：不先查后插（TOCTOU），索引冲突即同步点。code_of 的
        # first-find 与 any-match 等价：handle_write_error 的 cond 只返回一个映射
        # 错误，Invalid 树至多一个 BusinessError 叶。
        if code_of(error) == "event_slug_taken" do
          classify_slug_conflict(row, idx, workspace_id, error)
        else
          failed_row(row, idx, code_of(error), error_detail(error))
        end
    end
  end

  defp classify_slug_conflict(row, idx, workspace_id, error) do
    slug = row["slug"]

    event =
      Event
      |> Ash.Query.for_read(:get_by_slug, %{slug: slug})
      |> Ash.Query.select([:id, :slug, :title, :workspace_id])
      |> Ash.read_one(authorize?: false)

    case event do
      # read-back 仅判行归属（同工作台 → 幂等 skip），不是授权面——行级 create
      # 已带 actor 走过完整 policy，被索引拒下；authorize?: false 免 field_policy
      # 干扰归属判定。
      {:ok, %Event{workspace_id: ^workspace_id} = event} ->
        %{row: idx, status: "skipped", event_id: event.id, slug: slug, title: event.title}

      _other ->
        failed_row(row, idx, code_of(error), error_detail(error))
    end
  end

  # ---- 行级错误转译（结构化：code 既有码透传 + field + message）----

  defp failed_row(row, idx, code, detail) do
    %{
      row: idx,
      status: "failed",
      slug: Map.get(row, "slug"),
      title: Map.get(row, "title"),
      error: Map.put(detail, :code, code)
    }
  end

  # code 只透传既有 BusinessError 码（变量传递，不新增码）；无 BusinessError 叶子
  # 时为 nil（#241 契约面只认 domain 层字面量，本工具零新增）。
  defp code_of(%Ash.Error.Invalid{errors: leaves}) when is_list(leaves) do
    Enum.find_value(leaves, fn
      %BusinessError{code: code} when is_binary(code) -> code
      _ -> nil
    end)
  end

  defp code_of(_), do: nil

  # 已知 Invalid 树：混合树（已映射 + 未映射叶）整条降级（#612 / Mcp.Errors 同
  # 口径）——未映射叶不逐叶渲染成发明文案，走统一出口拿 database_error + error
  # id 关联服务端日志；纯已映射树才逐叶转译。
  # 未预期错误形态同走统一出口（#612 纪律：lib/mcp 唯一允许错误树转字符串的地方）。
  defp error_detail(%Ash.Error.Invalid{} = error) do
    if DatabaseError.unmapped?(error) do
      %{message: Cgc2046.Mcp.Errors.message(error, "failed to create event"), fields: []}
    else
      fold_leaves(error)
    end
  end

  defp error_detail(error),
    do: %{message: Cgc2046.Mcp.Errors.message(error, "failed to create event"), fields: []}

  # 逐叶转译（Ash 原序、", " 拼接，同 Mcp.Errors 折叠口径）：message 取叶子原始
  # message 字段（validation 已提供完整文案，不走 Exception.message 渲染——
  # vars 缺失时的 "Value: nil" 路径 #680 已消灭，这里不重新引入）；fields 取并集。
  defp fold_leaves(%Ash.Error.Invalid{errors: leaves}) when is_list(leaves) do
    {messages, fields} =
      Enum.reduce(leaves, {[], []}, fn leaf, {msgs, flds} ->
        {[leaf_message(leaf) | msgs], leaf_fields(leaf) ++ flds}
      end)

    %{message: messages |> Enum.reverse() |> Enum.join(", "), fields: Enum.uniq(fields)}
  end

  defp leaf_message(%BusinessError{message: message}) when is_binary(message), do: message
  defp leaf_message(%{message: message}) when is_binary(message), do: message
  defp leaf_message(_), do: "invalid value"

  defp leaf_fields(%BusinessError{fields: fields}), do: List.wrap(fields)
  defp leaf_fields(%{field: field}) when is_atom(field), do: [field]
  defp leaf_fields(_), do: []

  # ---- 行级白名单取参（判别法与 CreateEvent.take_fields 同源：string 键由
  # Wrapper 顶层归一保证；nil = 未提供，false 是合法显式值不能 || 收集；
  # 字段清单单源 CreateEvent.create_fields/0）----

  defp take_fields(row, fields) do
    fields
    |> Enum.filter(fn field -> not is_nil(Map.get(row, field)) end)
    |> Map.new(fn field -> {String.to_existing_atom(field), Map.get(row, field)} end)
  end
end

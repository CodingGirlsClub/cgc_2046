defmodule Cgc2046Web.GraphqlSchema.Offering.Types do
  @moduledoc """
  Offering 治理域 GraphQL 类型：admin 行/详情投影、挂载预览、治理 update
  输入与各 payload；仅本域 notation 模块 import_types 使用。
  """

  use Absinthe.Schema.Notation

  # U2 治理读面：offering（Event / Course）行与详情两组投影（KTD3/KTD4）——
  #   行（admin_event / admin_course）：listAdminEvents / listAdminCourses 用。
  #     跨租户定位与生命周期按钮所需的最小集（带 workspace_id，前端用既有
  #     workspaces 数据映射名称）；**不带报名计数**——计数需要按场现取，属于
  #     开弹窗/展开详情那一次取数（KTD4）。
  #   详情（admin_event_detail / admin_course_detail）：get 查询用 = 行字段 +
  #     处置与排查字段（权威报名计数、主理人、挂载来源标记 / 版本指针）。
  object :admin_event do
    field(:id, non_null(:id))
    field(:workspace_id, non_null(:id))
    field(:title, non_null(:string))
    field(:slug, :string)
    field(:status, non_null(:string), description: "draft | open | closed | cancelled")
    field(:visibility, non_null(:string), description: "public | workspace")
    field(:capacity, :integer, description: "报名名额上限；nil 表示不限")
    field(:registration_deadline, :datetime)
    field(:starts_at, :datetime)
    field(:ends_at, :datetime)
    field(:pricing_enabled, non_null(:boolean))
    field(:deposit_enabled, non_null(:boolean))
    field(:deposit_amount_cents, :integer)
    field(:inserted_at, non_null(:datetime))
    field(:updated_at, non_null(:datetime))
  end

  object :admin_event_detail do
    field(:id, non_null(:id))
    field(:workspace_id, non_null(:id))
    field(:title, non_null(:string))
    field(:slug, :string)
    field(:description, :string)
    field(:status, non_null(:string), description: "draft | open | closed | cancelled")
    field(:visibility, non_null(:string), description: "public | workspace")
    field(:capacity, :integer, description: "报名名额上限；nil 表示不限")
    field(:registration_deadline, :datetime)
    field(:starts_at, :datetime)
    field(:ends_at, :datetime)
    @desc "结构化场地 JSON 串（country/province/city/district；nil = 线上或未定）"
    field(:venue, :json_string)
    field(:pricing_enabled, non_null(:boolean))
    field(:deposit_enabled, non_null(:boolean))
    field(:deposit_amount_cents, :integer)

    @desc """
    权威已确认报名笔数（KTD4：按本场现取 `Enrollment.status == confirmed` 行数，
    不读 events.confirmed_count 展示投影——该列自述可能滞后一拍）。
    nil = 计数不可用（现取失败）；界面必须按不可用态呈现并禁用依赖它的入口，
    不得当 0。0 表示真实无已确认报名（免费场零计数）。
    """
    field(:confirmed_count, :integer)

    @desc """
    权威待付报名笔数（KTD4：`Enrollment.status == payment_pending` 行数）。
    关定价/关押金槽位的后果披露与 200 笔批量免缴上限判定都以此数为准；nil 语义
    同 confirmedCount（不可用，非 0）。
    """
    field(:payment_pending_count, :integer)

    @desc "主理人清单（平台管理员读面不要求本台成员身份）；nil = 清单加载失败（不阻断详情主读）"
    field(:moderators, list_of(non_null(:event_moderator)))

    @desc "解除挂载来源标记 JSON（事件被 detach 后仍留在场上的锁死值来自哪个 Initiative）；nil = 无标记。公开面不暴露（治理详情专属）"
    field(:detached_rule_provenance, :json_string)

    field(:inserted_at, non_null(:datetime))
    field(:updated_at, non_null(:datetime))
  end

  object :admin_course do
    field(:id, non_null(:id))
    field(:workspace_id, non_null(:id))
    field(:title, non_null(:string))
    @desc "标题是否为系统生成的临时占位（未命名课程）；发布前置门，治理列表据此标黄"
    field(:provisional_title, non_null(:boolean))
    field(:slug, :string)
    field(:status, non_null(:string), description: "draft | open | closed | cancelled")
    field(:visibility, non_null(:string), description: "public | workspace")
    field(:capacity, :integer, description: "报名名额上限；nil 表示不限")
    field(:registration_deadline, :datetime)
    field(:starts_at, :datetime)
    field(:ends_at, :datetime)
    field(:pricing_enabled, non_null(:boolean))
    field(:inserted_at, non_null(:datetime))
    field(:updated_at, non_null(:datetime))
  end

  object :admin_course_detail do
    field(:id, non_null(:id))
    field(:workspace_id, non_null(:id))
    field(:title, non_null(:string))
    @desc "标题是否为系统生成的临时占位（未命名课程）；发布前置门，治理列表据此标黄"
    field(:provisional_title, non_null(:boolean))
    field(:slug, :string)
    field(:description, :string)
    field(:status, non_null(:string), description: "draft | open | closed | cancelled")
    field(:visibility, non_null(:string), description: "public | workspace")
    field(:capacity, :integer, description: "报名名额上限；nil 表示不限")
    field(:registration_deadline, :datetime)
    field(:starts_at, :datetime)
    field(:ends_at, :datetime)
    field(:pricing_enabled, non_null(:boolean))

    @desc "当前绑定修订号（计划 R3：按 current_revision_id 现取 CourseRevision.number）。nil = 未绑定（draft 未发布常态）或现取失败，不得伪造"
    field(:current_revision_number, :integer)

    @desc """
    权威已确认报名笔数（KTD4：按本课现取 `Enrollment.status == confirmed` 行数，
    不读 courses.confirmed_count 展示投影）。nil = 计数不可用（现取失败），
    不得当 0；0 表示真实无已确认报名。
    """
    field(:confirmed_count, :integer)

    @desc "权威待付报名笔数（KTD4：`Enrollment.status == payment_pending` 行数）；nil 语义同 confirmedCount"
    field(:payment_pending_count, :integer)

    field(:inserted_at, non_null(:datetime))
    field(:updated_at, non_null(:datetime))
  end

  object :initiative_mount_preview do
    field(:initiative_id, non_null(:id))
    field(:name, non_null(:string))
    field(:slug, non_null(:string))
    field(:status, non_null(:string))
    field(:rules, non_null(list_of(non_null(:initiative_rule_preview))))
    field(:missing_rules, non_null(list_of(non_null(:string))))
  end

  # value_json 与 AdminInitiativeRule 同口径（JSON 字符串 + locked 布尔）：
  # 手写客户端复用既有 JSON.parse(rule.valueJson) 解析模式
  object :initiative_rule_preview do
    field(:key, non_null(:string))
    field(:value_json, non_null(:string))
    field(:locked, non_null(:boolean))
  end

  # U1 治理 update 输入（键集 = `@admin_event_update_fields` / `@admin_course_update_fields`；
  # 未提供的字段不落 changeset——map_input/2 只取存在的键）
  input_object :admin_event_update_input do
    field(:title, :string)
    field(:slug, :string)
    field(:description, :string)
    field(:visibility, :string)
    field(:capacity, :integer)
    field(:registration_deadline, :datetime)
    field(:starts_at, :datetime)
    field(:ends_at, :datetime)
    field(:venue, :json_string)
    field(:pricing_enabled, :boolean)
    field(:deposit_enabled, :boolean)
  end

  input_object :admin_course_update_input do
    field(:title, :string)
    field(:slug, :string)
    field(:description, :string)
    field(:visibility, :string)
    field(:capacity, :integer)
    field(:registration_deadline, :datetime)
    field(:starts_at, :datetime)
    field(:ends_at, :datetime)
    field(:pricing_enabled, :boolean)
  end

  # U1：治理写 payload 回**资源本体**（Event/Course 既有 GraphQL 类型）——前端
  # 写成功后即可就地更新行，亦可按 KTD4 单一取数契约重取治理投影。
  object :admin_event_payload do
    description("治理写（Event）结果信封：result + errors，形状同 adminInitiativePayload")

    field(:result, :event)
    field(:errors, list_of(:mutation_error))
  end

  object :admin_course_payload do
    description("治理写（Course）结果信封：result + errors，形状同 adminInitiativePayload")

    field(:result, :course)
    field(:errors, list_of(:mutation_error))
  end

  object :admin_initiative_rule_payload do
    field(:result, :admin_initiative_rule)
    field(:errors, list_of(:mutation_error))
  end

  # #537 回显平铺：displayName → memberNumber fallback 链的数据面（nullable；
  # member_number 由 uuid 确定性现算恒非空，display_name 可空）
  object :event_moderator do
    field(:id, non_null(:id))
    field(:workspace_id, non_null(:id))
    field(:event_id, non_null(:id))
    field(:user_id, non_null(:id))
    field(:assigned_by, :id)
    field(:assigned_at, non_null(:datetime))
    field(:user_display_name, :string)
    field(:user_member_number, :string)
    field(:assigned_by_display_name, :string)
    field(:assigned_by_member_number, :string)
  end

  object :event_moderator_payload do
    field(:result, :event_moderator)
    field(:errors, list_of(:mutation_error))
  end

  # U5/KTD4 核销 payload：成功返回到场事实（enrollment_id / checked_in_at / method），
  # 失败（码无效 / 已核销）三者皆为 null 且 errors 携带领域 code（前端按 code 查文案）。
  # 退款侧状态（押金已发起 / 已在退还中 / 已退，KTD6 分派）随 U6 落地后在此扩展。
  object :check_in_enrollment_payload do
    @desc "被核销的报名（失败为 null）"
    field(:enrollment_id, :id)

    @desc "核销时间（失败为 null）"
    field(:checked_in_at, :datetime)

    @desc "核销方式：scan / manual（失败为 null）"
    field(:method, :string)

    @desc """
    本次核销的押金退款侧事实（KTD6），成功路径只可能返回：
    - null：该报名没有押金单（免费/定价场报名，或押金制之前建的存量报名）→ 本次核销不产生退款；
    - refunding：本次核销已发起全额退款，或押金已在退还中（幂等重入不重复退；refund_failed 归一为 refunding）；
    - refunded：押金已退。
    forfeited 不会出现在成功路径——押金已没收时核销本身失败，走 errors 的 deposit_already_forfeited。
    前端据此决定是否显示「押金退款已发起」，不再只看事件是不是押金场。
    """
    field(:deposit_refund, :string)

    field(:errors, list_of(:mutation_error))
  end
end

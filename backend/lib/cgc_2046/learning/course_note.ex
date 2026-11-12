defmodule Cgc2046.Learning.CourseNote do
  @moduledoc """
  学员课程笔记（服务端真源）。

  归属：`user_id + course_id + issue_id`；`course_revision_id` 只是创建时
  的课程版本快照，不参与归属，课程重发布后笔记仍可见。

  生命周期：
  - `kind = :note`：用户笔记；同 `dedupe_hash` 唯一；删除是硬删除；
  - `kind = :retro`：服务端按 revision 生成的复盘；`retro_key` 唯一；
    删除写 `deleted_at` 墓碑，避免 `ensure_retro` 自动重建。

  读/写默认只允许本人；课程访问由 `Cgc2046.Learning.CourseNotes` 在创建/
   复盘生成前校验，资源层 owner policy 兜底。
  """

  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    domain: Cgc2046.Learning

  attributes do
    uuid_primary_key(:id)

    attribute(:workspace_id, :uuid, allow_nil?: false, public?: false, writable?: true)
    attribute(:user_id, :uuid, allow_nil?: false, public?: false, writable?: true)
    attribute(:course_id, :uuid, allow_nil?: false, public?: false, writable?: true)
    attribute(:course_revision_id, :uuid, allow_nil?: true, public?: false, writable?: true)
    attribute(:issue_id, :string, allow_nil?: false, public?: false, writable?: true)
    attribute(:source_material_id, :string, allow_nil?: true, public?: false, writable?: true)

    attribute(:kind, :atom,
      allow_nil?: false,
      public?: false,
      writable?: true,
      constraints: [one_of: [:note, :retro]]
    )

    attribute(:text, :string,
      allow_nil?: false,
      public?: false,
      writable?: true,
      constraints: [max_length: 4000]
    )

    attribute(:dedupe_hash, :string, allow_nil?: true, public?: false, writable?: true)
    attribute(:retro_key, :string, allow_nil?: true, public?: false, writable?: true)
    attribute(:deleted_at, :utc_datetime_usec, allow_nil?: true, public?: false, writable?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to(:workspace, Cgc2046.Accounts.Workspace,
      source_attribute: :workspace_id,
      destination_attribute: :id,
      allow_nil?: false
    )

    belongs_to(:user, Cgc2046.Accounts.User,
      source_attribute: :user_id,
      destination_attribute: :id,
      allow_nil?: false
    )

    belongs_to(:course, Cgc2046.Courses.Course,
      source_attribute: :course_id,
      destination_attribute: :id,
      allow_nil?: false
    )

    belongs_to(:course_revision, Cgc2046.Curriculum.CourseRevision,
      source_attribute: :course_revision_id,
      destination_attribute: :id,
      allow_nil?: true
    )
  end

  identities do
    # NOTE 的唯一去重键；RETRO 的 dedupe_hash 为 nil，Postgres 唯一索引允许
    # 多条 NULL，因此不会与笔记互相干扰。
    identity(:unique_note, [:user_id, :course_id, :issue_id, :dedupe_hash])
    # RETRO 的幂等键（含已删除墓碑）；NOTE 的 retro_key 为 nil。
    identity(:unique_retro, [:retro_key])
  end

  actions do
    defaults([:read])

    create :create_note do
      accept([
        :workspace_id,
        :user_id,
        :course_id,
        :course_revision_id,
        :issue_id,
        :source_material_id,
        :kind,
        :text,
        :dedupe_hash,
        :retro_key
      ])
    end

    update :update_note do
      accept([:text, :dedupe_hash])
    end

    update :mark_deleted do
      accept([:deleted_at])
    end

    destroy(:destroy_note)
  end

  postgres do
    table("learning_course_notes")
    repo(Cgc2046.Repo)

    references do
      reference(:workspace, on_delete: :delete)
      reference(:user, on_delete: :delete)
      reference(:course, on_delete: :delete)
      reference(:course_revision, on_delete: :nothing)
    end

    custom_indexes do
      index([:user_id, :course_id, :inserted_at])
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if(expr(user_id == ^actor(:id)))
    end
  end
end

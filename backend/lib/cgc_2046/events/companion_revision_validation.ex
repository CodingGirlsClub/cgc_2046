defmodule Cgc2046.Events.CompanionRevisionValidation do
  @moduledoc """
  `course_revision_id` 配套课程锚点校验（issue #505 D1，VenueValidation 同款挂法）。

  create/update 挂锚入库前：锚定 revision 必须**同租户存在且已 published**——
  防挂草稿版种出学员读不到内容的 learning run（`get_course_revision` 学员面
  仅放行最新 published 版）。nil（拆锚/宣讲会）直接放行。

  tenant 解析沿 create action 的 argument 回退纪律（workspace_id argument 或
  changeset.tenant，event.ex:315-321）。
  """

  use Ash.Resource.Validation

  require Ash.Query

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :course_revision_id) do
      nil ->
        :ok

      revision_id ->
        workspace_id =
          changeset.tenant || Ash.Changeset.get_argument(changeset, :workspace_id)

        if published_revision?(workspace_id, revision_id) do
          :ok
        else
          {:error,
           field: :course_revision_id,
           message: "course_revision_id must reference a published course revision"}
        end
    end
  end

  defp published_revision?(nil, _revision_id), do: false

  # 发布状态判定列 = published_at（CourseRevision 无 status 字段，非空即
  # published——与 get_course_revision 学员面口径一致）。
  defp published_revision?(workspace_id, revision_id) do
    Cgc2046.Curriculum.CourseRevision
    |> Ash.Query.filter(id == ^revision_id and not is_nil(published_at))
    |> Ash.Query.set_tenant(workspace_id)
    |> Ash.exists?(authorize?: false)
  end
end

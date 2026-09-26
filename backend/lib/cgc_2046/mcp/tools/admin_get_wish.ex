defmodule Cgc2046.Mcp.Tools.AdminGetWish do
  @moduledoc """
  许愿详情（U9/R18，platform_admin）：全文 + 留言流 + 附议名单；**含联系方式**
  （线下联系发起人所需，A2）——仅详情面暴露。已软删许愿仍可按 id 读
  （核对删除生效；`deleted_at` 明示治理态）。
  """
  use Anubis.Server.Component,
    type: :tool,
    meta: %{workspace_id: :optional, membership: :platform_admin}

  alias Cgc2046.Flashback.{Wish, Wishes}
  alias Cgc2046.Mcp.Wrapper
  require Ash.Query

  # 发给调用方 agent 的工具描述（只写契约）；@moduledoc 留给维护者
  @impl true
  def description do
    """
    平台管理员专用：读取一条许愿的详情：全文、留言、附议名单，以及发起人的联系方式（只有本工具返回
    联系方式，用于线下联系发起人）。已删除的许愿仍可读取，deleted_at 非空即已删除。
    """
  end

  schema do
    field(:wish_id, :string, description: "许愿 id（admin_list_wishes 返回）", required: true)
  end

  @impl true
  def execute(params, frame) do
    result =
      Wrapper.run(frame, params, "admin_get_wish", fn _actor, _ws, params ->
        fetch_wish(params["wish_id"])
      end)

    Cgc2046.Mcp.Tools.Response.to_response(result, frame)
  end

  defp fetch_wish(wish_id) when is_binary(wish_id) and wish_id != "" do
    Wish
    |> Ash.Query.filter(id == ^wish_id)
    |> Ash.Query.load([:endorsements, :comments, :person])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} ->
        {:error, "wish not found"}

      {:ok, wish} ->
        {:ok, detail(wish)}

      error ->
        error
    end
  end

  defp fetch_wish(_), do: {:error, "wish not found"}

  defp detail(wish) do
    wisher = wish.person

    %{
      id: wish.id,
      content: wish.content,
      visibility: wish.visibility,
      city: wish.city,
      created_at: wish.inserted_at,
      deleted_at: wish.deleted_at,
      wisher: %{
        person_id: wish.person_id,
        full_name: wisher && wisher.full_name,
        city: wisher && wisher.city,
        email: wisher && wisher.email,
        phone: wisher && wisher.phone
      },
      endorsement_count: length(wish.endorsements),
      comments:
        Enum.map(Wishes.list_comments(wish.id), fn c ->
          %{
            id: c.id,
            content: c.content,
            commenter_masked: c.commenter_masked,
            inserted_at: c.inserted_at
          }
        end)
    }
  end
end

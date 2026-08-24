defmodule Cgc2046.Events.Venue do
  @moduledoc """
  结构化场地的纯函数族（KTD5 / R2）。

  v1 场地 = Event 的 `venue` jsonb 单嵌入 map（无独立表、不引行政区划依赖），
  恰四键、值均字符串：

      %{
        "country" => "中国",
        "province" => "浙江省",
        "city" => "杭州市",
        "district" => "西湖区"
      }

  Course 为线上课程，无 venue。nil 合法（线上/未定）；公开面按层级键过滤。
  """

  @venue_keys ["country", "province", "city", "district"]

  @doc "结构性校验 venue map：恰四键且值均为字符串。"
  @spec valid?(term()) :: boolean()
  def valid?(venue) when is_map(venue) do
    Enum.sort(Map.keys(venue)) == Enum.sort(@venue_keys) and
      Enum.all?(@venue_keys, &is_binary(venue[&1]))
  end

  def valid?(_venue), do: false
end

defmodule Cgc2046.Events.VenueValidation do
  @moduledoc """
  `venue` 字段结构校验（Ash Resource.Validation）。

  create/update 入库前拒绝畸形 map（SponsorshipTiersValidation 同款挂法，
  message-only 不触发错误码契约再生成）。
  """

  use Ash.Resource.Validation

  alias Cgc2046.Events.Venue

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :venue) do
      nil ->
        :ok

      venue ->
        if Venue.valid?(venue) do
          :ok
        else
          {:error,
           field: :venue,
           message: "venue must be a map with country/province/city/district string keys"}
        end
    end
  end
end

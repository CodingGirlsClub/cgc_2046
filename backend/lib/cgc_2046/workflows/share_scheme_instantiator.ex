defmodule Cgc2046.Workflows.ShareSchemeInstantiator do
  @moduledoc """
  分享链接预生成订阅方（plan 011 P3，D-1 拍板：活动发布时预生成）。

  订阅 `event.launched` / `course.launched` → 入队 Oban job
  （`Cgc2046.Miniprogram.ShareSchemeWorker`）异步调 `ShareSchemeService.fetch_or_generate/2`
  ——微信外呼不进信号同步路径（发布事务不等平台 API）。

  幂等两层：本订阅方 claim_first（同信号重投不重复入队）；worker 执行
  fetch_or_generate 天然幂等（未过期命中复用零外呼）。claim 后入队失败/
  重试耗尽时该目标预生成缺失，由渠道消费侧 lazy fetch_or_generate 重建
  （at-most-once 取舍同 Notifications.Subscriber）。
  """

  use Cgc2046.Workflows.SignalSubscriber,
    patterns: ["event.launched", "course.launched"],
    idempotency: :claim_first,
    consumer_key: "share_scheme_instantiator"

  require Logger

  alias Cgc2046.Miniprogram.ShareSchemeWorker

  @impl Cgc2046.Workflows.SignalSubscriber
  def handle(_type, %{"event_id" => event_id}) when is_binary(event_id) do
    enqueue(:event, event_id)
  end

  def handle(_type, %{"course_id" => course_id}) when is_binary(course_id) do
    enqueue(:course, course_id)
  end

  def handle(_type, data) do
    Logger.warning("ShareSchemeInstantiator received signal without entity id: #{inspect(data)}")
    :ok
  end

  defp enqueue(kind, target_id) do
    case ShareSchemeWorker.new(%{target_kind: kind, target_id: target_id}) |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end

defmodule Cgc2046.Notifications.InboxSnapshotTest do
  use ExUnit.Case, async: true
  alias Cgc2046.Notifications.{InboxSnapshot, NotificationWorker}

  test "all existing types produce only user-facing snapshots and never copy raw channel secrets" do
    id = "1ac8d8d6-4c3c-4f61-9364-6a4eb80ee23a"

    data = %{
      "title" => "活动",
      "status" => "confirmed",
      "cohort_name" => "招募",
      "position_label" => "志愿者",
      "event_title" => "活动",
      "assignment_note" => "安排",
      "rejection_reason" => "暂不符合条件",
      "cancel_note" => "已取消",
      "content_preview" => "希望开展阅读活动",
      "event_id" => id,
      "wish_id" => id,
      "outcome" => "confirmed",
      "amount" => "12.00",
      "starts_at" => "2026-10-04T09:00:00Z",
      "check_in_code" => "987654",
      "provider" => "SENSITIVE_SENTINEL",
      "authorization" => "SENSITIVE_SENTINEL",
      "cookie" => "SENSITIVE_SENTINEL",
      "reset_secret" => "SENSITIVE_SENTINEL",
      "raw_payload" => %{"anything" => "SENSITIVE_SENTINEL"}
    }

    for type <- NotificationWorker.types() |> Enum.map(& &1.template_key) |> Enum.uniq() do
      assert %{payload: %{"title" => title, "body" => body} = payload, deep_link: _} =
               InboxSnapshot.build(type, data, %{})

      assert Enum.sort(Map.keys(payload)) == ["body", "title"]
      refute String.contains?(Jason.encode!(payload), "SENSITIVE_SENTINEL")
      refute String.contains?(body, "987654")
      assert String.length(title) <= 80
      assert String.length(body) <= 280
    end

    assert InboxSnapshot.build("unknown", data, %{}) == nil
  end

  test "snapshots carry approved status and times, not arbitrary links" do
    assert %{payload: %{"body" => "活动：报名未通过。"}} =
             InboxSnapshot.build(
               "approval_result",
               %{"title" => "活动", "status" => "rejected"},
               %{}
             )

    assert %{payload: %{"body" => body}, deep_link: nil} =
             InboxSnapshot.build(
               "event_schedule_changed",
               %{
                 "title" => "活动",
                 "starts_at" => "2026-10-04T09:00:00Z",
                 "venue" => %{"city" => "杭州", "district" => "西湖"},
                 "event_id" => "https://evil",
                 "deep_link" => "https://evil"
               },
               %{}
             )

    assert body == "活动：活动时间或地点已更新。：2026-10-04 17:00：杭州西湖"
  end
end

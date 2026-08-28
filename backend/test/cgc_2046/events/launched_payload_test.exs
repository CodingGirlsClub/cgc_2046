defmodule Cgc2046.Events.LaunchedPayloadTest do
  @moduledoc """
  ADR-0009 KD8/R9：event.launched / course.launched 信号 payload 键逐字节冻结。
  直调 launched_payload/2 钉住键集合与 research_requirements ← curriculum_requirements
  映射（键名不随属性改名）。
  """

  use ExUnit.Case, async: true

  alias Cgc2046.Courses.Course
  alias Cgc2046.Events.Event

  test "Event launched_payload 冻结键集合，research_requirements 取 curriculum_requirements" do
    requirements = %{"topics" => ["elixir"], "depth" => "intro"}
    event = %Event{id: "evt-1", title: "Elixir Night", curriculum_requirements: requirements}

    assert Event.launched_payload(nil, event) == %{
             "event_id" => "evt-1",
             "title" => "Elixir Night",
             "research_requirements" => requirements
           }
  end

  test "Event launched_payload：curriculum_requirements 为 nil 时回落 %{}（键仍在）" do
    event = %Event{id: "evt-2", title: "T", curriculum_requirements: nil}

    payload = Event.launched_payload(nil, event)

    assert Map.has_key?(payload, "research_requirements")
    assert payload["research_requirements"] == %{}
  end

  test "Course launched_payload 冻结键集合，research_requirements 取 curriculum_requirements" do
    requirements = %{"topics" => ["phoenix"]}
    course = %Course{id: "crs-1", title: "Phoenix 101", curriculum_requirements: requirements}

    assert Course.launched_payload(nil, course) == %{
             "course_id" => "crs-1",
             "title" => "Phoenix 101",
             "research_requirements" => requirements
           }
  end

  test "Course launched_payload：curriculum_requirements 为 nil 时回落 %{}（键仍在）" do
    course = %Course{id: "crs-2", title: "T", curriculum_requirements: nil}

    payload = Course.launched_payload(nil, course)

    assert Map.has_key?(payload, "research_requirements")
    assert payload["research_requirements"] == %{}
  end
end

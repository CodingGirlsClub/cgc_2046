defmodule Cgc2046.Curriculum.ContentTest do
  use ExUnit.Case, async: true

  alias Cgc2046.Curriculum.Content

  defp issue(materials) do
    %{
      "id" => "issue-1",
      "kind" => "handwork",
      "title" => "练习",
      "chapter_id" => "chapter-1",
      "story" => %{
        "as_a" => "学员",
        "given" => [],
        "goal" => "完成练习",
        "materials" => materials,
        "checklist" => [%{"id" => "check-1", "text" => "完成"}]
      },
      "objectives" => [
        %{
          "id" => "objective-1",
          "title" => "能完成练习",
          "required" => true,
          "prereq_ids" => [],
          "materials" => materials,
          "activity" => "练习",
          "assessment" => "提交结果",
          "rubric" => [%{"id" => "rubric-1", "text" => "结果正确"}]
        }
      ]
    }
  end

  defp content(materials) do
    %{
      "goals" => ["学会"],
      "chapters" => [%{"id" => "chapter-1", "title" => "第一章"}],
      "issues" => [issue(materials)]
    }
  end

  test "accepts chapters and typed materials" do
    materials = [
      %{"kind" => "text", "title" => "说明", "body" => "正文"},
      %{"kind" => "markdown", "title" => "笔记", "body" => "**重点**"},
      %{"kind" => "web", "title" => "文档", "url" => "https://example.com"},
      %{
        "kind" => "image",
        "title" => "图片",
        "url" => "https://example.com/a.png",
        "alt_text" => "图"
      },
      %{
        "kind" => "video",
        "title" => "视频",
        "provider" => "bilibili",
        "external_id" => "BV1Q541167Qg"
      }
    ]

    assert Content.valid_v1?(content(materials))
    assert Content.chapters(content(materials)) == [%{"id" => "chapter-1", "title" => "第一章"}]
    assert Content.material_kinds() == ["text", "markdown", "web", "image", "video"]
  end

  test "rejects an issue that points to a missing chapter" do
    invalid = put_in(content([])["issues"] |> hd(), ["chapter_id"], "missing")
    refute Content.valid_v1?(invalid)
  end

  test "rejects unsafe or unknown typed material" do
    refute Content.valid_v1?(
             content([%{"kind" => "web", "title" => "危险", "url" => "javascript:alert(1)"}])
           )

    refute Content.valid_v1?(
             content([
               %{
                 "kind" => "video",
                 "title" => "未知",
                 "provider" => "unknown",
                 "external_id" => "x"
               }
             ])
           )
  end
end

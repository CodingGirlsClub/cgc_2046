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

  test "reports legacy materials and rejects malformed Bilibili IDs" do
    legacy = content([%{"title" => "旧链接", "ref" => "https://example.com"}])
    messages = Content.material_violations(legacy)
    assert length(messages) == 2
    assert Enum.all?(messages, &String.contains?(&1, "legacy_material_ref"))

    refute Content.valid_v1?(
             content([
               %{
                 "kind" => "video",
                 "title" => "视频",
                 "provider" => "bilibili",
                 "external_id" => "BV1xx"
               }
             ])
           )

    refute Content.valid_v1?(
             content([%{"kind" => "image", "title" => "图", "url" => "https://example.com/a.png"}])
           )

    refute Content.valid_v1?(
             content([
               %{
                 "kind" => "web",
                 "title" => "私有",
                 "url" => "https://example.com",
                 "access_scope" => "enrolled"
               }
             ])
           )
  end

  test "image 材料须含 trim 后非空 alt_text(H3:missing_material_metadata)" do
    no_alt = %{"kind" => "image", "title" => "图", "url" => "https://example.com/a.png"}
    blank_alt = Map.put(no_alt, "alt_text", "   ")

    refute Content.valid_v1?(content([no_alt]))
    refute Content.valid_v1?(content([blank_alt]))

    messages = Content.material_violations(content([blank_alt]))
    assert length(messages) == 2
    assert Enum.all?(messages, &String.contains?(&1, "missing_material_metadata"))
    assert Enum.any?(messages, &String.contains?(&1, ~s(issue "issue-1" story.materials[0])))
    assert Enum.any?(messages, &String.contains?(&1, ~s(objective "objective-1" materials[0])))
  end

  test "显式 access/access_scope 仅允许 public(H4:invalid_material_access_scope)" do
    video = fn scope ->
      Map.merge(
        %{
          "kind" => "video",
          "title" => "视频",
          "provider" => "bilibili",
          "external_id" => "BV1Q541167Qg"
        },
        scope
      )
    end

    # public 放行(两键均认);缺键放行(向后兼容既有 typed 材料);
    # 未知展示键不参与判定(保 round-trip,与 H4 不冲突——scope 键是显式语义键)
    assert Content.valid_v1?(content([video.(%{"access_scope" => "public"})]))
    assert Content.valid_v1?(content([video.(%{"access" => "public"})]))
    assert Content.valid_v1?(content([video.(%{})]))
    assert Content.valid_v1?(content([video.(%{"caption" => "花絮"})]))

    # enrolled/workspace/low_sensitivity/任意收窄值拒绝(两键均认)
    for scope <- [
          %{"access_scope" => "enrolled"},
          %{"access_scope" => "workspace"},
          %{"access_scope" => "low_sensitivity"},
          %{"access" => "enrolled"}
        ] do
      refute Content.valid_v1?(content([video.(scope)]))

      assert Enum.all?(
               Content.material_violations(content([video.(scope)])),
               &String.contains?(&1, "invalid_material_access_scope")
             )
    end
  end

  test "javascript: 来源报 invalid_material_source 且带位置路径" do
    bad = %{"kind" => "web", "title" => "危险", "url" => "javascript:alert(1)"}
    refute Content.valid_v1?(content([bad]))

    messages = Content.material_violations(content([bad]))
    assert length(messages) == 2
    assert Enum.all?(messages, &String.contains?(&1, "invalid_material_source"))
    assert Enum.any?(messages, &String.contains?(&1, ~s(issue "issue-1" story.materials[0])))
  end
end

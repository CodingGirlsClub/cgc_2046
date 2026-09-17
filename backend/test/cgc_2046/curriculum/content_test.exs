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

  test "合规 content:shape_violations 为空(valid_v1? 的规则单源)" do
    assert Content.shape_violations(content([])) == []
    assert Content.valid_v1?(content([]))
  end

  test "checklist 放 issue 卡顶层 → 点名 story.checklist 与非卡顶层(#677 事故回归)" do
    [%{"story" => story} = issue | rest] = content([])["issues"]

    misplaced =
      issue
      |> Map.put("checklist", story["checklist"])
      |> Map.put("story", Map.delete(story, "checklist"))

    bad = %{content([]) | "issues" => [misplaced | rest]}

    refute Content.valid?(bad)
    refute Content.valid_v1?(bad)

    violations = Content.shape_violations(bad)
    assert Enum.any?(violations, &(&1 =~ "story.checklist"))
    assert Enum.any?(violations, &(&1 =~ "非卡顶层"))
    assert Enum.any?(violations, &(&1 =~ "卡顶层有 checklist 键"))
  end

  test "story 内省略 checklist(未放卡顶层)同样点名 story.checklist" do
    [%{"story" => story} = issue | rest] = content([])["issues"]

    bad = %{
      content([])
      | "issues" => [Map.put(issue, "story", Map.delete(story, "checklist")) | rest]
    }

    refute Content.valid_v1?(bad)
    assert Enum.any?(Content.shape_violations(bad), &(&1 =~ "story.checklist"))
  end

  test "shape_violations 覆盖每个 v1 形状族,且每条单行" do
    base = content([])
    [issue | rest] = base["issues"]

    cases = %{
      "goals 非数组" => %{base | "goals" => %{"a" => 1}},
      "goals 空" => %{base | "goals" => []},
      "goals 含非字符串" => %{base | "goals" => ["g", 1]},
      "issues 非数组" => %{base | "issues" => "x"},
      "issues 空" => %{base | "issues" => []},
      "issue 非 map" => %{base | "issues" => ["x"]},
      "issue 缺 id" => %{base | "issues" => [Map.delete(issue, "id") | rest]},
      "kind 非法" => %{base | "issues" => [%{issue | "kind" => "other"} | rest]},
      "title 空" => %{base | "issues" => [%{issue | "title" => ""} | rest]},
      "story 缺失" => %{base | "issues" => [Map.delete(issue, "story") | rest]},
      "checklist 条目缺 text" => %{
        base
        | "issues" => [
            put_in(issue, ["story", "checklist"], [%{"id" => "check-1"}]) | rest
          ]
      },
      "checklist id 重复" => %{
        base
        | "issues" => [
            put_in(issue, ["story", "checklist"], [
              %{"id" => "check-1", "text" => "a"},
              %{"id" => "check-1", "text" => "b"}
            ])
            | rest
          ]
      },
      "story.materials 非数组" => %{
        base
        | "issues" => [put_in(issue, ["story", "materials"], "x") | rest]
      },
      "issue id 重复" => %{base | "issues" => [issue, issue]},
      "chapter_id 引用不存在" => %{
        base
        | "issues" => [Map.put(issue, "chapter_id", "missing") | rest]
      },
      "chapter_id 非字符串" => %{base | "issues" => [Map.put(issue, "chapter_id", 1) | rest]},
      "chapters 非数组" => %{base | "chapters" => %{}},
      "chapters 缺 title" => %{base | "chapters" => [%{"id" => "chapter-1"}]},
      "chapters id 重复" => %{
        base
        | "chapters" => [
            %{"id" => "c", "title" => "一"},
            %{"id" => "c", "title" => "二"}
          ]
      }
    }

    for {name, bad} <- cases do
      violations = Content.shape_violations(bad)

      assert violations != [], "#{name}:shape_violations 未拦下"
      refute Content.valid_v1?(bad), "#{name}:valid_v1? 未拦下"

      assert Enum.all?(violations, &(is_binary(&1) and not String.contains?(&1, "\n"))),
             "#{name}:违规文案须单行"
    end
  end

  test "非 map 的 issue 条目报违规而非崩溃(旧 valid_v1? 在此抛 FunctionClauseError)" do
    bad = %{"goals" => ["g"], "issues" => ["x"]}

    refute Content.valid_v1?(bad)
    assert Enum.any?(Content.shape_violations(bad), &(&1 =~ "issue[1] 须为 map"))
  end

  test "shape_violations 不回显用户内容,位置标签换行清洗" do
    bad = %{
      "goals" => %{"SECRET" => "SECRET"},
      "issues" => [
        %{
          "id" => "ev\nil",
          "kind" => "other",
          "title" => "SECRET-TITLE",
          "story" => %{"checklist" => nil}
        }
      ]
    }

    text = bad |> Content.shape_violations() |> Enum.join(" | ")

    refute text =~ "SECRET"
    refute text =~ "\n"
    assert text =~ "goals 须为非空字符串数组,当前:map"
    assert text =~ ~s(issue "ev il")
    assert text =~ "kind 须为 thoughtwork 或 handwork"

    binary_text =
      %{"goals" => ["SECRET"], "issues" => "SECRET-ISSUES"}
      |> Content.shape_violations()
      |> Enum.join(" | ")

    refute binary_text =~ "SECRET"
    assert binary_text =~ "issues 须为非空 issue 卡数组,当前:string(13)"
  end

  test "shape_summary 固定 3 个契约键且不回显内容" do
    summary =
      Content.shape_summary(%{"goals" => ["SECRET"], "issues" => [1, 2], "extra" => "SECRET"})

    assert summary == %{"goals" => "list(1)", "chapters" => "nil", "issues" => "list(2)"}
    refute inspect(summary) =~ "SECRET"
  end
end

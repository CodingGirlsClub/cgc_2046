defmodule Cgc2046.Curriculum.OutputTest do
  @moduledoc """
  Curriculum.Output 资源测试(切片 H U1, #180):

  - 首次保存 kind=:issues 成功,key 形如 course_<id>,(key,kind) 唯一
  - 同 key 二次保存为更新(活文档),不产生第二行
  - 内容形状校验(goals 非空数组 / issues 非空 / issue 缺 id / checklist
    item id 重复 / kind 非法值 → changeset 报错,Covers R2)
  - 跨租户读写被 policy 拒绝
  """
  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  require Ash.Query

  alias Cgc2046.EventsFixtures, as: EventFixtures
  alias Cgc2046.Curriculum.Output

  defp content_fixture(attrs \\ %{}) do
    Map.merge(
      %{
        "goals" => ["能写简单程序"],
        "issues" => [
          %{
            "id" => "py-first-program",
            "kind" => "handwork",
            "title" => "写你的第一个程序",
            "story" => %{
              "as_a" => "刚装好 Python 的学员",
              "given" => ["无"],
              "goal" => "独立写一个问候程序",
              "materials" => [%{"title" => "Python 官方教程", "ref" => "https://example.com"}],
              "checklist" => [
                %{"id" => "c1", "text" => "程序能运行并正确输出"},
                %{"id" => "c2", "text" => "能把代码逐行讲懂"}
              ]
            },
            "objectives" => [
              %{
                "id" => "obj-1",
                "title" => "掌握本单元核心目标",
                "rubric" => [%{"id" => "r1", "text" => "能独立完成"}]
              }
            ]
          },
          %{
            "id" => "py-variables",
            "kind" => "thoughtwork",
            "title" => "变量与数据",
            "story" => %{
              "as_a" => "完成第一节的学员",
              "given" => ["py-first-program"],
              "goal" => "理解变量存取",
              "materials" => [],
              "checklist" => [%{"id" => "c1", "text" => "能解释变量的绑定与读出"}]
            },
            "objectives" => [
              %{
                "id" => "obj-2",
                "title" => "掌握变量概念",
                "rubric" => [%{"id" => "r1", "text" => "能解释绑定与读出"}]
              }
            ]
          }
        ]
      },
      attrs
    )
  end

  defp upsert(workspace, actor, course, content, attrs \\ %{}) do
    Output
    |> Ash.Changeset.for_create(
      :upsert_content,
      Map.merge(
        %{
          key: Output.course_key(course.id),
          kind: :issues,
          data: content,
          submitted_by: actor.id,
          workflow_run_id: course.workflow_run_id,
          base_version: 0
        },
        attrs
      ),
      tenant: workspace.id,
      actor: actor
    )
    |> Ash.create(tenant: workspace.id, actor: actor)
  end

  describe "首次保存与 (key,kind) 唯一" do
    test "kind=:issues 落库成功,key 形如 course_<id>" do
      admin = Fixtures.platform_admin("ro-save")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{title: "Python 入门"})

      assert {:ok, output} = upsert(workspace, admin, course, content_fixture())

      assert output.key == "course_#{course.id}"
      assert output.kind == :issues
      assert output.submitted_by == admin.id
      assert output.workspace_id == workspace.id
      assert output.data["goals"] == ["能写简单程序"]
      assert length(output.data["issues"]) == 2
    end

    test "同 (key,kind) 再插入被数据库唯一索引拒绝(upsert 之外的直插路径)" do
      admin = Fixtures.platform_admin("ro-uniq")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{})
      {:ok, _} = upsert(workspace, admin, course, content_fixture())

      # 裸 SQL 直插绕过 upsert 语义,唯一索引兜底:撞全局 (key,kind) 唯一 →
      # num_rows=0(Postgres ON CONFLICT DO NOTHING 无冲突时为 1)
      {:ok, result} =
        Ecto.Adapters.SQL.query(
          Repo,
          "INSERT INTO curriculum_outputs (id, workspace_id, key, kind, data, submitted_by) " <>
            "VALUES ($1, $2, $3, 'issues', $4::jsonb, $5) ON CONFLICT DO NOTHING",
          [
            Ecto.UUID.dump!(Ecto.UUID.generate()),
            Ecto.UUID.dump!(workspace.id),
            Output.course_key(course.id),
            Jason.encode!(content_fixture()),
            Ecto.UUID.dump!(admin.id)
          ]
        )

      assert result.num_rows == 0
    end
  end

  describe "活文档更新" do
    test "同 key 二次保存为更新,不产生第二行;version 递增(S4)" do
      admin = Fixtures.platform_admin("ro-live")
      workspace = Fixtures.create_workspace(admin)
      tutor = Fixtures.register_user("ro-live-tutor")
      Fixtures.add_member(workspace, tutor, [:tutor])
      course = EventFixtures.create_course(workspace, admin, %{title: "课程"})

      {:ok, first} = upsert(workspace, tutor, course, content_fixture())
      assert first.version == 1

      updated_content = content_fixture(%{"goals" => ["目标 v2"]})

      assert {:ok, second} = upsert(workspace, admin, course, updated_content, %{base_version: 1})

      # 更新面:data 与 submitted_by;key/kind 是身份不改;version 1 → 2
      assert second.id == first.id
      assert second.data["goals"] == ["目标 v2"]
      assert second.submitted_by == admin.id
      assert second.version == 2

      assert [row] =
               Output
               |> Ash.Query.filter(workspace_id == ^workspace.id)
               |> Ash.read!(authorize?: false, tenant: workspace.id)

      assert row.id == first.id
    end
  end

  describe "草稿版本契约(S4,base_version 乐观并发)" do
    test "缺 base_version → 必填错误" do
      admin = Fixtures.platform_admin("ro-ver-req")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{})

      assert {:error, error} =
               Output
               |> Ash.Changeset.for_create(
                 :upsert_content,
                 %{
                   key: Output.course_key(course.id),
                   kind: :issues,
                   data: content_fixture(),
                   submitted_by: admin.id
                 },
                 tenant: workspace.id,
                 actor: admin
               )
               |> Ash.create(tenant: workspace.id, actor: admin)

      assert Exception.message(error) =~ "base_version is required"
    end

    test "首存传非 0 base_version(无草稿行)→ version_conflict 语义(version 0)" do
      admin = Fixtures.platform_admin("ro-ver-first")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{})

      assert {:error, error} =
               upsert(workspace, admin, course, content_fixture(), %{base_version: 1})

      assert Exception.message(error) =~ "version_conflict: draft is at version 0"
      assert Exception.message(error) =~ "get_course_content"

      # 草稿未落库
      assert Output
             |> Ash.Query.filter(key == ^Output.course_key(course.id))
             |> Ash.read!(authorize?: false, tenant: workspace.id) == []
    end

    test "陈旧 base_version → StaleRecord,行保持不变" do
      admin = Fixtures.platform_admin("ro-ver-stale")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{})

      {:ok, first} = upsert(workspace, admin, course, content_fixture())

      # 以过期基准(0)再写:行已存在(version 1),upsert_condition 不命中
      # (StaleRecord 经事务回滚包装为 Invalid 类返回)
      assert {:error, %Ash.Error.Invalid{errors: stale1}} =
               upsert(workspace, admin, course, content_fixture(%{"goals" => ["覆盖"]}))

      assert Enum.any?(stale1, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

      # 以 version 1 写成功 → version 2;再用同一基准写 → StaleRecord
      assert {:ok, second} =
               upsert(workspace, admin, course, content_fixture(), %{base_version: first.version})

      assert second.version == 2

      assert {:error, %Ash.Error.Invalid{errors: stale2}} =
               upsert(
                 workspace,
                 admin,
                 course,
                 content_fixture(%{"goals" => ["覆盖"]}),
                 %{base_version: 1}
               )

      assert Enum.any?(stale2, &match?(%Ash.Error.Changes.StaleRecord{}, &1))

      reloaded = Ash.get!(Output, first.id, authorize?: false, tenant: workspace.id)
      assert reloaded.version == 2
      assert reloaded.data["goals"] == ["能写简单程序"]
    end
  end

  describe "内容形状校验(Covers R2)" do
    test "issues 为空 → 报错" do
      admin = Fixtures.platform_admin("ro-v-empty")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{})

      assert {:error, changeset} =
               upsert(workspace, admin, course, content_fixture(%{"issues" => []}))

      assert %{errors: errors} = changeset
      assert Enum.any?(errors, &(&1.field == :data or is_nil(&1.field)))
    end

    test "issue 缺 id → 报错" do
      admin = Fixtures.platform_admin("ro-v-id")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{})

      [first_issue | rest] = content_fixture()["issues"]

      assert {:error, _changeset} =
               upsert(workspace, admin, course, %{
                 "issues" => [Map.delete(first_issue, "id") | rest],
                 "goals" => ["g"]
               })
    end

    test "checklist item id 在 issue 内重复 → 报错" do
      admin = Fixtures.platform_admin("ro-v-dup")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{})

      [first_issue | rest] = content_fixture()["issues"]

      dup =
        Map.put(
          first_issue,
          "story",
          Map.put(first_issue["story"], "checklist", [
            %{"id" => "c1", "text" => "条目一"},
            %{"id" => "c1", "text" => "条目二(重复 id)"}
          ])
        )

      assert {:error, _changeset} =
               upsert(workspace, admin, course, %{"goals" => ["g"], "issues" => [dup | rest]})
    end

    test "issue id 卡集内重复 → 报错" do
      admin = Fixtures.platform_admin("ro-v-iid")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{})

      [first_issue | _] = content_fixture()["issues"]

      assert {:error, _changeset} =
               upsert(workspace, admin, course, %{
                 "goals" => ["g"],
                 "issues" => [first_issue, first_issue]
               })
    end

    test "kind 非法值(:materials 后置)→ changeset 报错" do
      admin = Fixtures.platform_admin("ro-v-kind")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{})

      assert {:error, changeset} =
               upsert(workspace, admin, course, content_fixture(), %{kind: :materials})

      assert %{errors: errors} = changeset
      assert Enum.any?(errors, &(&1.field == :kind))
    end
  end

  describe "租户 policy" do
    test "非成员(非平台管理员)读写被拒" do
      admin = Fixtures.platform_admin("ro-tenant")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{})
      outsider = Fixtures.register_user("ro-tenant-outsider")

      assert {:error, %Ash.Error.Forbidden{}} =
               upsert(workspace, outsider, course, content_fixture())

      # 读面同样非 Forbidden:读 policy 全拒 → 查询被置空(Ash 读门禁语义,
      # 同 actor_reads_offering 家族),非成员读不到租户内任何行
      assert {:ok, []} =
               Output
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: workspace.id, actor: outsider)
    end

    test "平台管理员可跨租户读(global 审计面)" do
      admin = Fixtures.platform_admin("ro-admin")
      workspace = Fixtures.create_workspace(admin)
      course = EventFixtures.create_course(workspace, admin, %{})
      {:ok, _} = upsert(workspace, admin, course, content_fixture())

      assert {:ok, [output]} =
               Output
               |> Ash.Query.for_read(:read)
               |> Ash.read(tenant: workspace.id, actor: admin)

      assert output.key == Output.course_key(course.id)
    end
  end
end

defmodule Cgc2046.Initiatives.RulePreviewTest do
  @moduledoc """
  #596 挂载前规则预览读面：Owner/Admin 可读四规则值与锁态；普通成员/非成员/
  非成员平台管理员一律 forbidden（先判权再读库，不泄存在性）。
  """
  use Cgc2046.DataCase, async: true

  alias Cgc2046.AccountsFixtures, as: Fixtures
  alias Cgc2046.Initiatives.{Initiative, InitiativeRule, RulePreview}

  setup do
    %{owner: owner, workspace: workspace, member: member} = Fixtures.workspace_with_member()
    admin = Fixtures.platform_admin("rule-preview-admin")

    %{
      owner: owner,
      workspace: workspace,
      member: member,
      admin: admin,
      initiative: initiative_with_rules(admin, "rule-preview", :open)
    }
  end

  defp initiative_with_rules(admin, slug, status, rules \\ nil) do
    initiative =
      Initiative
      |> Ash.Changeset.for_create(:create, %{
        name: "预览 #{slug}",
        slug: slug,
        created_by: admin.id
      })
      |> Ash.create!(actor: admin)

    rules =
      rules ||
        [
          {:deposit, %{enabled: true, amount_cents: 6900}, true},
          {:age_gate, %{min_age: 18}, true},
          {:min_participants, %{count: 8}, false},
          {:deadline_rule, %{hours_before_start: 72}, false}
        ]

    for {key, value, locked} <- rules do
      InitiativeRule
      |> Ash.Changeset.for_create(:create, %{
        initiative_id: initiative.id,
        key: key,
        value: value,
        locked: locked
      })
      |> Ash.create!(actor: admin)
    end

    if status == :open do
      initiative |> Ash.Changeset.for_update(:open, %{}) |> Ash.update!(actor: admin)
    else
      initiative
    end
  end

  test "Owner 读到四规则的值与锁态（固定序），status/slug/name 齐备", ctx do
    assert {:ok, preview} =
             RulePreview.get(ctx.initiative.id, ctx.owner, ctx.workspace.id)

    assert preview.initiative_id == ctx.initiative.id
    assert preview.name == ctx.initiative.name
    assert preview.slug == "rule-preview"
    assert preview.status == "open"
    assert preview.missing_rules == []

    assert preview.rules == [
             %{key: "deposit", value: %{"enabled" => true, "amount_cents" => 6900}, locked: true},
             %{key: "age_gate", value: %{"min_age" => 18}, locked: true},
             %{key: "min_participants", value: %{"count" => 8}, locked: false},
             %{key: "deadline_rule", value: %{"hours_before_start" => 72}, locked: false}
           ]
  end

  test "普通成员 forbidden（工作台成员不等于可读规则）", ctx do
    assert {:error, :forbidden} = RulePreview.get(ctx.initiative.id, ctx.member, ctx.workspace.id)
  end

  test "非成员 forbidden", ctx do
    outsider = Fixtures.register_user("rule-preview-outsider")
    assert {:error, :forbidden} = RulePreview.get(ctx.initiative.id, outsider, ctx.workspace.id)
  end

  test "非成员平台管理员 forbidden（该面无 platform_admin 豁免，治理读走 admin_get_initiative）",
       ctx do
    assert {:error, :forbidden} = RulePreview.get(ctx.initiative.id, ctx.admin, ctx.workspace.id)
  end

  test "无权者对不存在的 id 仍只得 forbidden（不泄存在性）", ctx do
    assert {:error, :forbidden} =
             RulePreview.get(Ecto.UUID.generate(), ctx.member, ctx.workspace.id)
  end

  test "不存在的 id / 非法 uuid → not_found", ctx do
    assert {:error, :not_found} =
             RulePreview.get(Ecto.UUID.generate(), ctx.owner, ctx.workspace.id)

    assert {:error, :not_found} = RulePreview.get("not-a-uuid", ctx.owner, ctx.workspace.id)
  end

  test "规则未配齐的草稿：missing_rules 列出缺失键、status 暴露 draft", ctx do
    draft =
      initiative_with_rules(ctx.admin, "rule-preview-draft", :draft, [
        {:deposit, %{enabled: false}, false},
        {:age_gate, %{min_age: 18}, true}
      ])

    assert {:ok, preview} = RulePreview.get(draft.id, ctx.owner, ctx.workspace.id)
    assert preview.status == "draft"
    assert preview.missing_rules == ["min_participants", "deadline_rule"]
    assert Enum.map(preview.rules, & &1.key) == ["deposit", "age_gate"]
  end

  test "匿名（nil actor）forbidden", ctx do
    assert {:error, :forbidden} = RulePreview.get(ctx.initiative.id, nil, ctx.workspace.id)
  end
end

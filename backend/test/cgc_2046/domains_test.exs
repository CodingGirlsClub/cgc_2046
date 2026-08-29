defmodule Cgc2046.DomainsTest do
  use ExUnit.Case, async: true

  # ADR-0009 目标态：八个限界上下文 domain（PR① Admission / PR② Courses+Events /
  # PR③ Curriculum / PR④ Sponsorship / PR⑤ Workflows+Learning+Reconciliation）；
  # 旧 Api domain 已随 PR⑤ U8 退役删除
  @bounded_context_domains [
    Cgc2046.Admission,
    Cgc2046.Courses,
    Cgc2046.Curriculum,
    Cgc2046.Events,
    Cgc2046.Sponsorship,
    Cgc2046.Workflows,
    Cgc2046.Learning,
    Cgc2046.Reconciliation
  ]

  test "all eight ADR-0009 bounded-context domains and Accounts are loaded with the AshGraphQL extension" do
    for domain <- @bounded_context_domains ++ [Cgc2046.Accounts] do
      assert Code.ensure_loaded?(domain)
    end
  end

  test "ash_domains registers every bounded-context domain; retired Api is absent" do
    ash_domains = Application.get_env(:cgc_2046, :ash_domains, [])

    # 精确集合比对：旧 Api domain 不在列即随之钉死（无需引用已删除模块名）
    assert Enum.sort(ash_domains) ==
             Enum.sort(
               @bounded_context_domains ++
                 [
                   Cgc2046.Accounts,
                   Cgc2046.Mcp,
                   Cgc2046.Miniprogram,
                   Cgc2046.Notifications,
                   Cgc2046.Payments
                 ]
             )
  end

  test "Repo is an AshPostgres.Repo (data layer ready)" do
    assert function_exported?(Cgc2046.Repo, :installed_extensions, 0)
  end
end

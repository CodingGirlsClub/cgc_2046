defmodule Cgc2046.RbacContractTest do
  @moduledoc """
  golden-file 契约守卫（#1 能力接口收敛）。

  断言 `backend/priv/rbac_contract.json` 与 Rbac 单源（Role.role_names / Rbac.abilities_list /
  Rbac.matrix / Role.manage_roles）完全一致 —— 后端新增角色/能力或调整管理角色子集后须运行
  `mix cgc2046.gen_rbac_contract` 再生成，前端静态展示词汇测试
  （web/lib/permissions.contract.test.ts）据此守卫跨语言同步。

  纯函数测试，无 DB，可并行。
  """

  use ExUnit.Case, async: true

  alias Cgc2046.Accounts.Role
  alias Cgc2046.Rbac

  @contract_path Path.expand("../../priv/rbac_contract.json", __DIR__)

  test "committed rbac_contract.json exists and matches Rbac single source" do
    contract = File.read!(@contract_path) |> Jason.decode!()

    assert contract["roles"] ==
             Enum.map(Role.role_names(), &Atom.to_string/1)

    assert contract["abilities"] ==
             Enum.map(Rbac.abilities_list(), &Atom.to_string/1)

    expected_matrix =
      Enum.map(Rbac.matrix(), fn row ->
        %{
          "role" => Atom.to_string(row.role),
          "abilities" =>
            Map.new(row.abilities, fn {name, allowed} ->
              {Atom.to_string(name), allowed}
            end)
        }
      end)

    assert contract["matrix"] == expected_matrix,
           "rbac_contract.json 已过期 —— 运行 `mix cgc2046.gen_rbac_contract` 再生成"

    assert contract["manage_roles"] ==
             Enum.map(Role.manage_roles(), &Atom.to_string/1),
           "rbac_contract.json 已过期 —— 运行 `mix cgc2046.gen_rbac_contract` 再生成"
  end
end

defmodule Mix.Tasks.Cgc2046.GenRbacContract do
  @shortdoc "Regenerates priv/rbac_contract.json from the Rbac single source"

  @moduledoc """
  从 `Cgc2046.Accounts.Rbac` / `Cgc2046.Accounts.Role` 单源重新生成跨语言契约工件
  `backend/priv/rbac_contract.json`（roles / abilities / matrix / manage_roles）。

  #1 能力接口收敛：前端静态展示词汇（web/lib ROLE_NAMES / PERMISSION_ABILITIES）
  由 golden-file 契约测试守卫 —— 后端新增角色/能力后跑本任务再生成，
  前端不同步则 CI 红灯。manage_roles（管理角色子集，单源 `Role.manage_roles/0`）
  同样下发：前端 MANAGE_ROLE_NAMES 与之漂移即契约测试红灯。

  ## 用法

      mix cgc2046.gen_rbac_contract
  """

  use Mix.Task

  @switches [check: :boolean]

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, switches: @switches)

    contract = contract_payload()
    path = Path.expand("../../../priv/rbac_contract.json", __DIR__)

    if opts[:check] do
      case File.read(path) do
        {:ok, existing} ->
          if existing == contract do
            Mix.shell().info("rbac_contract.json is up to date")
          else
            Mix.raise("rbac_contract.json is stale — run `mix cgc2046.gen_rbac_contract`")
          end

        {:error, _} ->
          Mix.raise("rbac_contract.json is missing — run `mix cgc2046.gen_rbac_contract`")
      end
    else
      File.write!(path, contract)
      Mix.shell().info("wrote #{path}")
    end
  end

  defp contract_payload do
    roles = Enum.map(Cgc2046.Accounts.Role.role_names(), &Atom.to_string/1)
    abilities = Enum.map(Cgc2046.Accounts.Rbac.abilities_list(), &Atom.to_string/1)
    manage_roles = Enum.map(Cgc2046.Accounts.Role.manage_roles(), &Atom.to_string/1)

    matrix =
      Enum.map(Cgc2046.Accounts.Rbac.matrix(), fn row ->
        %{
          "role" => Atom.to_string(row.role),
          "abilities" =>
            Map.new(row.abilities, fn {name, allowed} ->
              {Atom.to_string(name), allowed}
            end)
        }
      end)

    Jason.encode!(
      %{
        "roles" => roles,
        "abilities" => abilities,
        "matrix" => matrix,
        "manage_roles" => manage_roles
      },
      pretty: true
    )
  end
end

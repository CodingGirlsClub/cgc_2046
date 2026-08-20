defmodule Cgc2046.Release do
  @moduledoc """
  Release 内 mix task 的替代入口（生产镜像无 mix，只有 bin/cgc_2046）。

  Kamal pre-deploy 钩子经 `bin/cgc_2046 eval "Cgc2046.Release.migrate"`
  在切流前完成迁移（见 .kamal/hooks/pre-deploy）。
  """

  @app :cgc_2046

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  # seeds 用 Ash read/create（非裸 Ecto），须起完整应用（含 Ash/registry）；
  # with_repo 只起 repo 不够。一次性容器内起 endpoint/Oban 无副作用：eval
  # 完即退出，端口不发布。seeds.exs 幂等（存在即跳过），重跑安全。
  def seed do
    load_app()
    Application.ensure_all_started(@app)

    seeds_path = Path.join([:code.priv_dir(@app), "repo", "seeds.exs"])
    Code.eval_file(seeds_path)
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  defp repos do
    Enum.filter(Application.fetch_env!(@app, :ecto_repos), &is_atom/1)
  end

  defp load_app do
    Application.load(@app)
  end
end

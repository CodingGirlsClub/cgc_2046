defmodule Cgc2046.Repo.Migrations.CreatePortfolioItems do
  @moduledoc """
  P1-4 G9：portfolio_items 表（用户作品集条目）。

  - user_id：所属用户（NOT NULL，外键 users.id，级联删除——用户删除时清空作品集）
  - title：作品标题（NOT NULL）
  - description / url：可空
  - icon：text（document/book/guide，默认 document）

  幂等：表已存在则跳过（dev 库 / 重复执行安全）。
  """

  use Ecto.Migration

  def up do
    unless repo().query!(
             "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'portfolio_items'"
           ).num_rows > 0 do
      create table(:portfolio_items, primary_key: false) do
        add :id, :binary_id, primary_key: true
        add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
        add :title, :text, null: false
        add :description, :text
        add :url, :text
        add :icon, :text, null: false, default: "document"

        timestamps()
      end

      create index(:portfolio_items, [:user_id])
    end
  end

  def down do
    if repo().query!(
         "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'portfolio_items'"
       ).num_rows > 0 do
      drop table(:portfolio_items)
    end
  end
end

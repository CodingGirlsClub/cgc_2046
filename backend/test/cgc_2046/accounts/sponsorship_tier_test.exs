defmodule Cgc2046.Accounts.SponsorshipTierTest do
  use ExUnit.Case, async: true

  alias Cgc2046.Accounts.SponsorshipTier

  describe "valid?/1 白名单语义（E-3 #48 档位 json 形状）" do
    test "snake_case 完整档位 → 接受" do
      assert SponsorshipTier.valid?([
               %{
                 "id" => "t1",
                 "name" => "冠名",
                 "amount_suggestion" => 10_000,
                 "benefits" => ["logo 展示位"],
                 "exclusive" => true
               }
             ])
    end

    test "camelCase 键（amountSuggestion）→ 拒绝（白名单钉死：0e35a51 起前端曾误产此形状）" do
      refute SponsorshipTier.valid?([
               %{
                 "id" => "t1",
                 "name" => "冠名",
                 "amountSuggestion" => 10_000,
                 "benefits" => ["logo 展示位"],
                 "exclusive" => true
               }
             ])
    end

    test "未知键 → 拒绝" do
      refute SponsorshipTier.valid?([
               %{
                 "id" => "t1",
                 "name" => "冠名",
                 "benefits" => [],
                 "exclusive" => false,
                 "unknown_key" => 1
               }
             ])
    end
  end
end

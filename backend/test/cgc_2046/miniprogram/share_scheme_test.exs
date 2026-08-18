defmodule Cgc2046.Miniprogram.ShareSchemeTest do
  use Cgc2046.DataCase, async: false

  alias Cgc2046.Miniprogram.ShareScheme

  # 资源层契约测试（plan 011 P1）：upsert 幂等照 code.ex :50-53 先例
  # （identity :unique_target_platform + upsert_fields），模式照
  # miniprogram_code_test.exs（纯资源行为，无 HTTP mock）。

  describe "upsert 幂等（UK target_kind+target_id+platform）" do
    test "同 (kind,id,platform) 二次 upsert 更新不重复插入" do
      expires = DateTime.add(DateTime.utc_now(), 7, :day)

      assert {:ok, first} =
               ShareScheme
               |> Ash.Changeset.for_create(:create, %{
                 target_kind: :event,
                 target_id: "00000000-0000-4000-8000-000000000001",
                 platform: :wechat,
                 openlink: "weixin://dl/business/?t=FIRST",
                 expires_at: expires
               })
               |> Ash.create(authorize?: false)

      assert {:ok, second} =
               ShareScheme
               |> Ash.Changeset.for_create(:create, %{
                 target_kind: :event,
                 target_id: "00000000-0000-4000-8000-000000000001",
                 platform: :wechat,
                 openlink: "weixin://dl/business/?t=SECOND",
                 expires_at: DateTime.add(expires, 1, :day)
               })
               |> Ash.create(authorize?: false)

      # 复用同一行：id 不变、openlink/expires_at 覆盖
      assert second.id == first.id
      assert second.openlink == "weixin://dl/business/?t=SECOND"
      assert DateTime.compare(second.expires_at, expires) == :gt

      assert Ash.count!(ShareScheme, authorize?: false) == 1
    end

    test "不同 target / platform / kind 各自成行" do
      attrs = [
        %{
          target_kind: :event,
          target_id: "00000000-0000-4000-8000-0000000000a1",
          platform: :wechat
        },
        %{
          target_kind: :event,
          target_id: "00000000-0000-4000-8000-0000000000a2",
          platform: :wechat
        },
        %{
          target_kind: :course,
          target_id: "00000000-0000-4000-8000-0000000000a1",
          platform: :wechat
        }
      ]

      Enum.each(attrs, fn row ->
        assert {:ok, _} =
                 ShareScheme
                 |> Ash.Changeset.for_create(
                   :create,
                   Map.merge(row, %{
                     openlink: "weixin://dl/business/?t=#{row.target_kind}",
                     expires_at: DateTime.add(DateTime.utc_now(), 7, :day)
                   })
                 )
                 |> Ash.create(authorize?: false)
      end)

      assert Ash.count!(ShareScheme, authorize?: false) == 3
    end

    test "target_kind 约束：非法 kind 拒绝" do
      changeset =
        ShareScheme
        |> Ash.Changeset.for_create(:create, %{
          target_kind: :workshop,
          target_id: "00000000-0000-4000-8000-0000000000b1",
          platform: :wechat,
          openlink: "weixin://dl/business/?t=X",
          expires_at: DateTime.add(DateTime.utc_now(), 7, :day)
        })

      assert {:error, %Ash.Error.Invalid{}} = Ash.create(changeset, authorize?: false)
    end
  end
end

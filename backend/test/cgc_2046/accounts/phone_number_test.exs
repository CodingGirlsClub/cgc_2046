defmodule Cgc2046.Accounts.PhoneNumberTest do
  use Cgc2046.DataCase, async: true

  alias Cgc2046.Accounts.PhoneNumber

  describe "normalize/1 (web 登录入口，默认 +86)" do
    test "本地 11 位手机号拼默认区号" do
      assert {:ok, "+8613800138000"} = PhoneNumber.normalize("13800138000")
    end

    test "带 + 区号输入不重复拼接" do
      assert {:ok, "+8613800138000"} = PhoneNumber.normalize("+8613800138000")
    end

    test "空格与横线等分隔符被剥除（未归一化输入同号）" do
      assert {:ok, "+8613800138000"} = PhoneNumber.normalize("138-0013-8000")
      assert {:ok, "+8613800138000"} = PhoneNumber.normalize(" 138 0013 8000 ")
      assert {:ok, "+8613800138000"} = PhoneNumber.normalize("+86 138-0013-8000")
    end

    test "非数字字符全部剥除" do
      assert {:ok, "+8613800138000"} = PhoneNumber.normalize("tel:138,0013;8000#")
    end

    test "空串 / 纯非数字 / nil → invalid" do
      assert {:error, :invalid} = PhoneNumber.normalize("")
      assert {:error, :invalid} = PhoneNumber.normalize("  -  ")
      assert {:error, :invalid} = PhoneNumber.normalize(nil)
    end

    test "超长输入仍归一化（现状语义：长度不设上限，锁定防漂移）" do
      assert {:ok, "+861380013800000000000"} = PhoneNumber.normalize("1380013800000000000")
    end
  end

  describe "normalize/2 (小程序负载，显式区号)" do
    test "local + countryCode 拼接" do
      assert {:ok, "+8613800138000"} = PhoneNumber.normalize("13800138000", "86")
    end

    test "号码已以区号开头不重复拼接" do
      assert {:ok, "+8613800138000"} = PhoneNumber.normalize("8613800138000", "86")
    end

    test "国际区号" do
      assert {:ok, "+15551234567"} = PhoneNumber.normalize("5551234567", "1")
    end

    test "countryCode 缺失 fail-closed" do
      assert {:error, :invalid} = PhoneNumber.normalize("13800138000", nil)
      assert {:error, :invalid} = PhoneNumber.normalize("13800138000", "")
    end

    test "数字为空 fail-closed" do
      assert {:error, :invalid} = PhoneNumber.normalize(nil, "86")
      assert {:error, :invalid} = PhoneNumber.normalize("", "86")
    end
  end
end

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

  describe "parse/1 (web 入口：+E.164 或默认 +86)" do
    test "裸号沿用 +86 默认（既有行为不变）" do
      assert {:ok, "+8613800138000"} = PhoneNumber.parse("13800138000")
      assert {:ok, "+8613800138000"} = PhoneNumber.parse("138-0013-8000")
    end

    test "+86 整号（可含分隔符）不重复拼接" do
      assert {:ok, "+8613800138000"} = PhoneNumber.parse("+8613800138000")
      assert {:ok, "+8613800138000"} = PhoneNumber.parse("+86 138-0013-8000")
    end

    test "国际 E.164 整号保留原号（可含分隔符）" do
      assert {:ok, "+14155552671"} = PhoneNumber.parse("+14155552671")
      assert {:ok, "+447911123456"} = PhoneNumber.parse("+44 7911 123456")
      assert {:ok, "+85212345678"} = PhoneNumber.parse("+852 1234 5678")
      assert {:ok, "+819012345678"} = PhoneNumber.parse("+81-90-1234-5678")
    end

    test "国家码前缀非法 → invalid（fail-closed）" do
      assert {:error, :invalid} = PhoneNumber.parse("+999123456")
      assert {:error, :invalid} = PhoneNumber.parse("+0123456")
      assert {:error, :invalid} = PhoneNumber.parse("+")
    end

    test "空 / nil → invalid" do
      assert {:error, :invalid} = PhoneNumber.parse(nil)
      assert {:error, :invalid} = PhoneNumber.parse("")
    end
  end
end

defmodule Cgc2046.Flashback.CitiesTest do
  @moduledoc "KTD11 名单归一：精确匹配 / 后缀归一 / 候选 / 边界"
  use ExUnit.Case, async: true

  alias Cgc2046.Flashback.Cities

  describe "list/0" do
    test "~370 条、每条带 lng_lat 浮点数组" do
      cities = Cities.list()
      assert length(cities) >= 360 and length(cities) <= 380

      Enum.each(cities, fn c ->
        assert is_binary(c.short_name) and c.short_name != ""
        assert is_binary(c.full_name) and c.full_name != ""
        assert is_binary(c.pinyin)
        assert is_list(c.lng_lat) and length(c.lng_lat) == 2
        assert is_number(Enum.at(c.lng_lat, 0)) and is_number(Enum.at(c.lng_lat, 1))
        assert is_integer(c.adcode)
      end)
    end

    test "含港澳台三条短名映射" do
      by_short = Map.new(Cities.list(), &{&1.short_name, &1})
      assert Map.has_key?(by_short, "香港")
      assert Map.has_key?(by_short, "澳门")
      assert Map.has_key?(by_short, "台北")
      assert by_short["香港"].pinyin == "xianggang"
      assert by_short["澳门"].pinyin == "aomen"
      assert by_short["台北"].pinyin == "taibei"
    end

    test "含主要地级市" do
      shorts = MapSet.new(Enum.map(Cities.list(), & &1.short_name))
      for c <- ["成都", "上海", "北京", "广州", "深圳", "湘西", "阿坝", "拉萨", "乌鲁木齐"] do
        assert MapSet.member?(shorts, c)
      end
    end
  end

  describe "normalize/1 精确命中" do
    test "短名" do
      assert {:ok, "成都"} = Cities.normalize("成都")
      assert {:ok, "上海"} = Cities.normalize("上海")
      assert {:ok, "湘西"} = Cities.normalize("湘西")
      assert {:ok, "阿坝"} = Cities.normalize("阿坝")
      assert {:ok, "拉萨"} = Cities.normalize("拉萨")
      assert {:ok, "香港"} = Cities.normalize("香港")
      assert {:ok, "澳门"} = Cities.normalize("澳门")
      assert {:ok, "台北"} = Cities.normalize("台北")
    end

    test "全称" do
      assert {:ok, "成都"} = Cities.normalize("成都市")
      assert {:ok, "上海"} = Cities.normalize("上海市")
      assert {:ok, "湘西"} = Cities.normalize("湘西土家族苗族自治州")
      assert {:ok, "阿坝"} = Cities.normalize("阿坝藏族羌族自治州")
    end
  end

  describe "normalize/1 后缀归一" do
    test "剥「市」" do
      assert {:ok, "成都"} = Cities.normalize("成都市")
      assert {:ok, "广州"} = Cities.normalize("广州市")
    end

    test "剥「自治州」「地区」「盟」" do
      assert {:ok, "湘西"} = Cities.normalize("湘西土家族苗族自治州")
      assert {:ok, "阿坝"} = Cities.normalize("阿坝藏族羌族自治州")
      assert {:ok, "阿里"} = Cities.normalize("阿里地区")
      assert {:ok, "兴安"} = Cities.normalize("兴安盟")
    end

    test "剥「特别行政区」" do
      assert {:ok, "香港"} = Cities.normalize("香港特别行政区")
      assert {:ok, "澳门"} = Cities.normalize("澳门特别行政区")
    end
  end

  describe "normalize/1 边界" do
    test "空串 / nil / 全空格" do
      assert {:error, %{code: "flashback_wish_city_unknown"}} = Cities.normalize("")
      assert {:error, %{code: "flashback_wish_city_unknown"}} = Cities.normalize("   ")
      assert {:error, %{code: "flashback_wish_city_unknown"}} = Cities.normalize(nil)
    end

    test "超长输入" do
      assert {:error, %{code: "flashback_wish_city_unknown"}} =
               Cities.normalize(String.duplicate("a", 64))
    end

    test "非二进制输入" do
      assert {:error, %{code: "flashback_wish_city_unknown"}} = Cities.normalize(123)
      assert {:error, %{code: "flashback_wish_city_unknown"}} = Cities.normalize(%{})
    end

    test "全角空格与 NBSP 也算空格" do
      assert {:ok, "成都"} = Cities.normalize("　成都　")
    end
  end

  describe "normalize/1 错误携带 ≤3 候选" do
    test "前缀命中" do
      {:error, %{code: "flashback_wish_city_unknown", candidates: cands}} =
        Cities.normalize("长安")

      assert is_list(cands) and length(cands) <= 3
    end

    test "外城带候选文案" do
      {:error, %{code: "flashback_wish_city_unknown", candidates: cands, message: msg}} =
        Cities.normalize("某某某")

      assert is_binary(msg)
      assert is_list(cands) and length(cands) <= 3
    end
  end

  describe "metadata" do
    test "metadata 含指纹与数据来源" do
      meta = Cities.metadata()
      assert is_binary(meta["citiesMd5"])
      assert is_integer(meta["cityCount"])
      assert meta["source"] =~ "datav.aliyun.com"
    end
  end
end

defmodule Cgc2046.CheckLicensesTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Cgc2046.CheckLicenses

  describe "blacklisted?/1" do
    test "宽松许可全部放行" do
      for license <- [
            "MIT",
            "Apache-2.0",
            "BSD-2-Clause",
            "BSD-3-Clause",
            "ISC",
            "0BSD",
            "CC0-1.0",
            "BlueOak-1.0.0",
            "MIT-0",
            "Python-2.0",
            "Unlicense"
          ] do
        refute CheckLicenses.blacklisted?([license]), "#{license} 应放行"
      end
    end

    test "AGPL 兼容的弱 copyleft 放行" do
      for license <- ["MPL-2.0", "LGPL-3.0-or-later", "LGPL-3.0-only", "EPL-2.0", "CC-BY-4.0"] do
        refute CheckLicenses.blacklisted?([license]), "#{license} 应放行"
      end
    end

    test "GPL-2.0 系禁止（与 AGPL-3.0 不兼容）" do
      for license <- ["GPL-2.0-only", "GPL-2.0-or-later", "GPL-2.0", "gpl-2.0"] do
        assert CheckLicenses.blacklisted?([license]), "#{license} 应禁止"
      end
    end

    test "非 OSI / 专有许可禁止" do
      for license <- ["SSPL-1.0", "BUSL-1.1", "Elastic-2.0", "proprietary", "Commercial"] do
        assert CheckLicenses.blacklisted?([license]), "#{license} 应禁止"
      end
    end

    test "多选声明：含任一黑名单项即违规（严格模式）" do
      assert CheckLicenses.blacklisted?(["MIT", "BUSL-1.1"])
      assert CheckLicenses.blacklisted?(["GPL-2.0-only", "MIT"])
    end

    test "多选声明：全为宽松项则放行（bcrypt_elixir 案例）" do
      refute CheckLicenses.blacklisted?(["BSD-3-Clause", "ISC", "BSD-4-Clause"])
    end

    test "无许可声明 / 空列表 违规" do
      assert CheckLicenses.blacklisted?(nil)
      assert CheckLicenses.blacklisted?([])
    end
  end
end

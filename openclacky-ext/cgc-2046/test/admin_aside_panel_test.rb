# frozen_string_literal: true

# 管理侧栏(session.aside,attach cgc-admin)静态合同断言。
#
# 行为面(mcp_error 事件 → 断连横幅渲染 → 按钮跳回 hub)在 JS harness
# (test/panel_behavior_harness.js 的 admin_aside_mcp_error 场景);本文件
# 保留 harness 执行不到的源级合同锚。
#
# 运行(需项目 mise 环境):cd openclacky-ext/cgc-2046 && mise exec -- ruby test/admin_aside_panel_test.rb

require "minitest/autorun"

class AdminAsidePanelTest < Minitest::Test
  VIEW = File.read(File.expand_path("../panels/cgc-2046-admin-aside/view.js", __dir__))

  def test_mcp_error_banner_wired
    # plan 021:此前全包仅 hub 面板订阅 mcp_error,admin 侧栏断连零感知——
    # 侧栏必须订阅宿主扇出事件并渲染断连横幅(引导回 hub「连接网站」)
    assert_includes VIEW, "mcp_error"
    assert_includes VIEW, 'Clacky.ext.subscribe("ext.cgc-2046.mcp_error", onMcpError)'
    assert_includes VIEW, "cgaa-mcp-banner"
    assert_includes VIEW, "cgaa-banner-goto"
  end
end

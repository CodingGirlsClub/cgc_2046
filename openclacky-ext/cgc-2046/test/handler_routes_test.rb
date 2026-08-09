# frozen_string_literal: true

# 请求级 handler 测试：fake req + allocate 实例 + Halt 捕获（契约 §8 spec 先例）。
# FS 读写收敛在 Cgc2046McpConfig 的可 stub 模块函数上；除两个回滚磁盘级用例
# （Dir.mktmpdir 真实落盘验证逐字节恢复）外均不落盘。
#
# 运行（需项目 mise 环境）：cd openclacky-ext/cgc-2046 && mise exec -- ruby test/handler_routes_test.rb

require "minitest/autorun"
require "json"
require "tmpdir"

gem_spec = Gem::Specification.find_by_name("openclacky")
require File.join(gem_spec.gem_dir, "lib/clacky/extension/api_extension.rb")

require_relative "../api/handler"

class HandlerRequestTest < Minitest::Test
  TOKEN = "tok_test_secret_aaa"
  URL   = "http://localhost:4102/mcp"

  FakeReq = Struct.new(:body, :query)

  # 记录 reload 调用次数；fail_times 控制前 N 次抛错（之后成功）
  class FakeRegistry
    attr_reader :reload_count

    def initialize(fail_times: 0)
      @reload_count = 0
      @fail_times = fail_times
    end

    def reload
      @reload_count += 1
      if @fail_times > 0
        @fail_times -= 1
        raise "registry boom"
      end
    end
  end

  # handler 通过 @http_server.send(:mcp_registry) 取 registry（宿主为私有方法）
  class FakeServer
    def initialize(registry)
      @registry = registry
    end

    private

    def mcp_registry
      @registry
    end
  end

  # ---- 路由结构（保留首轮断言）----

  def test_routes_registered
    routes = Cgc2046Ext.routes.map { |r| [r.method, r.pattern] }

    assert_includes routes, [:post, "/connect"]
    assert_includes routes, [:delete, "/connect"]
    assert_includes routes, [:get, "/status"]
    assert_includes routes, [:post, "/skills/sync"]
    assert_equal 4, Cgc2046Ext.routes.size
    assert_equal 30.0, Cgc2046Ext.class_timeout
  end

  def test_write_mutex_exists
    assert_kind_of Mutex, Cgc2046Ext.write_mutex
  end

  # ---- connect 校验分支（422）----

  def test_connect_missing_token_422
    halt = invoke(:post, "/connect", build(body: JSON.generate("url" => URL)))

    assert_equal 422, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "token"
  end

  def test_connect_blank_token_422
    halt = invoke(:post, "/connect", build(body: JSON.generate("token" => "   ", "url" => URL)))

    assert_equal 422, halt.status
  end

  def test_connect_oversized_token_422
    halt = invoke(:post, "/connect", build(body: JSON.generate("token" => "t" * 513, "url" => URL)))

    assert_equal 422, halt.status
  end

  def test_connect_invalid_url_422
    halt = invoke(:post, "/connect", build(body: JSON.generate("token" => TOKEN, "url" => "ftp://nope")))

    assert_equal 422, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "http"
  end

  def test_connect_missing_url_422_when_no_config_default
    with_meta({}) do
      halt = invoke(:post, "/connect", build(body: JSON.generate("token" => TOKEN)))

      assert_equal 422, halt.status
      assert_includes JSON.parse(halt.payload)["error"], "url"
    end
  end

  # ---- connect 正常分支 ----

  def test_connect_success_merges_persists_and_reloads
    old = JSON.generate("mcpServers" => { "other" => { "type" => "stdio", "command" => "x" } })
    registry = FakeRegistry.new

    stub_fs(old_text: old) do |persisted|
      halt = invoke(:post, "/connect", build(
        body: JSON.generate("token" => TOKEN, "url" => URL),
        registry: registry
      ))

      # 200 证明 Halt（json/error!）未被 rescue StandardError 吞掉改写成 500
      assert_equal 200, halt.status
      payload = JSON.parse(halt.payload)
      assert_equal true, payload["ok"]
      assert_equal true, payload["created"]
      assert_equal URL, payload["url"]
      refute_includes halt.payload, TOKEN, "响应体不得含 token"

      assert_equal 1, persisted.size, "应恰好 persist 一次"
      _path, data = persisted.first
      entry = data.dig("mcpServers", "cgc")
      assert_equal "Bearer #{TOKEN}", entry.dig("headers", "Authorization"),
                   "token 的唯一去向是 mcp.json 的 headers"
      assert_equal({ "type" => "stdio", "command" => "x" }, data.dig("mcpServers", "other"),
                   "既有 server 条目语义无损")

      assert_equal 1, registry.reload_count, "写后必须 reload registry"
    end
  end

  def test_connect_existing_entry_reports_created_false
    old = JSON.generate("mcpServers" => { "cgc" => {
      "type" => "http", "url" => "http://old/mcp", "headers" => {}, "custom" => "keep"
    } })

    stub_fs(old_text: old) do |persisted|
      halt = invoke(:post, "/connect", build(
        body: JSON.generate("token" => TOKEN, "url" => URL),
        registry: FakeRegistry.new
      ))

      assert_equal 200, halt.status
      assert_equal false, JSON.parse(halt.payload)["created"]
      entry = persisted.first[1].dig("mcpServers", "cgc")
      assert_equal "keep", entry["custom"], "条目上的未知额外键必须保留"
      assert_equal "Bearer #{TOKEN}", entry.dig("headers", "Authorization")
    end
  end

  def test_connect_uses_config_default_url_when_body_omits_it
    with_meta({ "config" => { "mcp_url" => URL } }) do
      stub_fs(old_text: nil) do |persisted|
        halt = invoke(:post, "/connect", build(
          body: JSON.generate("token" => TOKEN),
          registry: FakeRegistry.new
        ))

        assert_equal 200, halt.status
        assert_equal URL, JSON.parse(halt.payload)["url"]
        assert_equal URL, persisted.first[1].dig("mcpServers", "cgc", "url")
      end
    end
  end

  # ---- connect 失败加固 ----

  def test_connect_reload_failure_rolls_back_raw_text_and_reloads_again
    old = JSON.generate("mcpServers" => { "other" => { "type" => "stdio", "command" => "x" } })
    registry = FakeRegistry.new(fail_times: 1)

    stub_fs(old_text: old) do |persisted, restored|
      halt = invoke(:post, "/connect", build(
        body: JSON.generate("token" => TOKEN, "url" => URL),
        registry: registry
      ))

      assert_equal 500, halt.status
      assert_includes JSON.parse(halt.payload)["error"], "reload"
      refute_includes halt.payload, TOKEN, "错误响应同样不得含 token"

      assert_equal 1, persisted.size, "正向写恰好一次"
      assert_equal 1, restored.size, "回滚写恰好一次"
      assert_equal old, restored.first[1],
                   "回滚必须写回进入时的原文 bytes（禁止 normalize 后重序列化）"

      assert_equal 2, registry.reload_count, "恢复落盘后必须 best-effort 再 reload 一次"
    end
  end

  # 磁盘级证据：旧文件是非法 JSON 时，reload 失败回滚必须逐字节恢复原样
  def test_connect_reload_failure_restores_invalid_json_bytes_on_disk
    Dir.mktmpdir do |dir|
      path = File.join(dir, "mcp.json")
      original = "not json at all {"
      File.write(path, original)
      registry = FakeRegistry.new(fail_times: 1)

      with_stubs(config_path: path) do
        halt = invoke(:post, "/connect", build(
          body: JSON.generate("token" => TOKEN, "url" => URL),
          registry: registry
        ))
        assert_equal 500, halt.status
      end

      assert_equal original, File.read(path), "磁盘内容必须逐字节恢复为原文（含非法 JSON）"
      assert_equal 2, registry.reload_count, "恢复后应有第二次 reload"
    end
  end

  # 磁盘级证据：旧文件不存在时，回滚 = 删掉新建文件 + 二次 reload
  def test_connect_reload_failure_deletes_new_file_when_none_existed
    Dir.mktmpdir do |dir|
      path = File.join(dir, "mcp.json")
      registry = FakeRegistry.new(fail_times: 1)

      with_stubs(config_path: path) do
        halt = invoke(:post, "/connect", build(
          body: JSON.generate("token" => TOKEN, "url" => URL),
          registry: registry
        ))
        assert_equal 500, halt.status
      end

      refute File.exist?(path), "旧文件不存在时回滚必须删除新建文件"
      assert_equal 2, registry.reload_count
    end
  end

  def test_connect_fs_error_500_without_token_leak
    registry = FakeRegistry.new
    raising = ->(_path, _hash) { raise Errno::EACCES, "Permission denied @ rb_sysopen - /fake/mcp.json.tmp" }

    with_stubs(config_path: "/fake/mcp.json", load_text: nil, persist: raising) do
      halt = invoke(:post, "/connect", build(
        body: JSON.generate("token" => TOKEN, "url" => URL),
        registry: registry
      ))

      assert_equal 500, halt.status
      assert_includes JSON.parse(halt.payload)["error"], "connect failed"
      refute_includes halt.payload, TOKEN
      assert_equal 0, registry.reload_count, "写盘失败不得触发 reload"
    end
  end

  # ---- status ----

  def test_status_configured_without_headers_or_token_leak
    old = JSON.generate("mcpServers" => { "cgc" => {
      "type" => "http", "url" => URL,
      "headers" => { "Authorization" => "Bearer tok_secret_status" },
      "description" => "x"
    } })

    stub_fs(old_text: old) do
      halt = invoke(:get, "/status", build)

      assert_equal 200, halt.status
      payload = JSON.parse(halt.payload)
      assert_equal true, payload["ok"]
      assert_equal true, payload["configured"]
      assert_equal true, payload["token_configured"], "有 Authorization header 时应报 token_configured:true"
      assert_equal URL, payload["url"]
      refute_includes halt.payload, "tok_secret_status", "status 不得泄漏 token"
      refute_includes halt.payload, "Bearer"
      refute_includes halt.payload, "headers"
    end
  end

  def test_status_unconfigured
    stub_fs(old_text: nil) do
      halt = invoke(:get, "/status", build)

      assert_equal 200, halt.status
      payload = JSON.parse(halt.payload)
      assert_equal false, payload["configured"]
      assert_equal false, payload["token_configured"]
      assert_nil payload["url"]
    end
  end

  def test_status_returns_web_url_from_config
    with_meta({ "config" => { "web_url" => "http://localhost:3000" } }) do
      stub_fs(old_text: nil) do
        halt = invoke(:get, "/status", build)

        assert_equal 200, halt.status
        assert_equal "http://localhost:3000", JSON.parse(halt.payload)["web_url"]
      end
    end
  end

  # ---- disconnect（DELETE /connect：移除 cgc 条目 + reload）----

  def test_disconnect_removes_and_reloads
    old = JSON.generate("mcpServers" => { "cgc" => {
      "type" => "http", "url" => URL,
      "headers" => { "Authorization" => "Bearer tok_old" }, "description" => "x"
    }, "other" => { "type" => "stdio", "command" => "x" } })
    registry = FakeRegistry.new

    stub_fs(old_text: old) do |persisted|
      halt = invoke(:delete, "/connect", build(registry: registry))

      assert_equal 200, halt.status
      payload = JSON.parse(halt.payload)
      assert_equal true, payload["ok"]
      assert_equal true, payload["removed"]

      assert_equal 1, persisted.size, "应恰好 persist 一次"
      _path, data = persisted.first
      assert_nil data.dig("mcpServers", "cgc"), "cgc 条目必须被移除"
      assert_equal({ "type" => "stdio", "command" => "x" }, data.dig("mcpServers", "other"),
                   "其它 server 条目语义无损")

      assert_equal 1, registry.reload_count, "写后必须 reload registry"
    end
  end

  def test_disconnect_noop_when_not_configured
    old = JSON.generate("mcpServers" => { "other" => { "type" => "stdio", "command" => "x" } })
    registry = FakeRegistry.new

    stub_fs(old_text: old) do |persisted|
      halt = invoke(:delete, "/connect", build(registry: registry))

      assert_equal 200, halt.status
      payload = JSON.parse(halt.payload)
      assert_equal true, payload["ok"]
      assert_equal false, payload["removed"], "无 cgc 条目时应为 no-op"

      assert_empty persisted, "no-op 时不得写盘（避免无谓重写/权限变化）"
      assert_equal 0, registry.reload_count, "no-op 时不得 reload"
    end
  end

  def test_disconnect_reload_failure_rolls_back_and_reloads_again
    old = JSON.generate("mcpServers" => { "cgc" => {
      "type" => "http", "url" => URL, "headers" => { "Authorization" => "Bearer tok_old" }
    }, "other" => { "type" => "stdio", "command" => "x" } })
    registry = FakeRegistry.new(fail_times: 1)

    stub_fs(old_text: old) do |persisted, restored|
      halt = invoke(:delete, "/connect", build(registry: registry))

      assert_equal 500, halt.status
      assert_includes JSON.parse(halt.payload)["error"], "reload"

      assert_equal 1, persisted.size, "正向移除写恰好一次"
      assert_equal 1, restored.size, "回滚写恰好一次"
      assert_equal old, restored.first[1],
                   "回滚必须写回进入时的原文 bytes（cgc 条目必须被恢复）"

      assert_equal 2, registry.reload_count, "恢复落盘后必须 best-effort 再 reload 一次"
    end
  end

  # ---- skills/sync（D11 留位）----

  def test_skills_sync_501
    halt = invoke(:post, "/skills/sync", build(body: "{}"))

    assert_equal 501, halt.status
    assert_includes JSON.parse(halt.payload)["error"], "later slice"
  end

  private

  # 手动构造实例（契约 §8 先例：allocate + 塞 ivar，不需要真 WEBrick req）
  def build(body: nil, registry: nil)
    inst = Cgc2046Ext.allocate
    inst.instance_variable_set(:@req, FakeReq.new(body, {}))
    inst.instance_variable_set(:@http_server, registry && FakeServer.new(registry))
    inst
  end

  def invoke(method, pattern, inst)
    route = Cgc2046Ext.routes.find { |r| r.method == method && r.pattern == pattern }
    refute_nil route, "route #{method} #{pattern} 未注册"
    assert_raises(Clacky::ApiExtension::Halt) { inst.instance_exec(&route.block) }
  end

  # 把 mcp.json 的读/写/路径全部 stub 掉；persist 记录序列化写，persist_text 记录原文写。
  # minitest 6 已移除 minitest/mock（无 Object#stub），用 singleton method 重定义实现。
  def stub_fs(old_text:)
    persisted = []
    restored = []
    writer = ->(path, hash) { persisted << [path, hash] }
    raw_writer = ->(path, text) { restored << [path, text] }

    stubs = {
      config_path:  "/fake/home/.clacky/mcp.json",
      load_text:    old_text,
      persist:      writer,
      persist_text: raw_writer
    }
    with_stubs(**stubs) { yield persisted, restored }
  end

  # 临时重定义 Cgc2046McpConfig 的模块函数，ensure 中恢复原实现。
  # 值语义：callable 直接作为实现；其它值包装成定值 lambda。
  def with_stubs(stubs)
    originals = {}
    stubs.each do |name, impl|
      originals[name] = Cgc2046McpConfig.method(name)
      fn = impl.respond_to?(:call) ? impl : ->(*_args) { impl }
      Cgc2046McpConfig.define_singleton_method(name, &fn)
    end
    yield
  ensure
    originals.each do |name, meth|
      Cgc2046McpConfig.define_singleton_method(name, meth)
    end
  end

  def with_meta(meta)
    old = Cgc2046Ext.meta
    Cgc2046Ext.meta = meta
    yield
  ensure
    Cgc2046Ext.meta = old
  end
end

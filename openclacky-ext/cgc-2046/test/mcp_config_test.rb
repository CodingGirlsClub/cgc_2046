# frozen_string_literal: true

# mcp_config 纯逻辑模块单测（test-first：先红后绿）。
# 只依赖 Ruby stdlib，不 require clacky gem。
#
# 运行（需项目 mise 环境）：cd openclacky-ext/cgc-2046 && mise exec -- ruby test/mcp_config_test.rb

require "minitest/autorun"
require "json"
require "tmpdir"
require "securerandom"

require_relative "../api/mcp_config"

class McpConfigTest < Minitest::Test
  # 连接条目标准 spec（handler 写入的四键）
  SPEC = {
    "type"        => "http",
    "url"         => "http://localhost:4102/mcp",
    "headers"     => { "Authorization" => "Bearer tok_secret_123" },
    "description" => "CGC-2046 platform capabilities"
  }.freeze

  # 1. 空/缺失数据 → 新建 mcpServers + cgc-2046 条目
  def test_upsert_creates_entry_on_empty_config
    result = Cgc2046McpConfig.upsert_server("{}", name: "cgc-2046", spec: SPEC)

    assert result[:created], "空配置上应为新建"
    assert_equal SPEC, result[:data]["mcpServers"]["cgc-2046"]
  end

  def test_upsert_creates_mcpservers_key_when_missing
    result = Cgc2046McpConfig.upsert_server('{"otherTop":1}', name: "cgc-2046", spec: SPEC)

    assert result[:created]
    assert_equal 1, result[:data]["otherTop"], "顶层其它键必须保留"
    assert_equal SPEC, result[:data]["mcpServers"]["cgc-2046"]
  end

  # 2. 已有其它 server 条目 → merge 后原条目语义无损保留
  def test_upsert_preserves_other_servers_semantically
    other = {
      "type"    => "stdio",
      "command" => "foo",
      "args"    => ["--bar", "baz"],
      "env"     => { "A" => "1" }
    }
    input = JSON.generate({ "mcpServers" => { "other" => other } })

    result = Cgc2046McpConfig.upsert_server(input, name: "cgc-2046", spec: SPEC)

    assert result[:created]
    assert_equal other, result[:data]["mcpServers"]["other"], "其它 server 条目内容不得变动"
    assert_equal SPEC, result[:data]["mcpServers"]["cgc-2046"]
  end

  # 3. 已有 cgc-2046 条目 → 只更新四键，未知额外键保留，其它 server 不动
  def test_upsert_updates_only_known_keys_and_keeps_extras
    input = JSON.generate(
      "mcpServers" => {
        "cgc-2046" => {
          "type"        => "http",
          "url"         => "http://old.example/mcp",
          "headers"     => { "Authorization" => "Bearer tok_old" },
          "description" => "old desc",
          "custom_note" => "keep me"
        },
        "other" => { "type" => "stdio", "command" => "x" }
      }
    )

    result = Cgc2046McpConfig.upsert_server(input, name: "cgc-2046", spec: SPEC)

    refute result[:created], "条目已存在时不是新建"
    entry = result[:data]["mcpServers"]["cgc-2046"]
    assert_equal "http://localhost:4102/mcp", entry["url"]
    assert_equal({ "Authorization" => "Bearer tok_secret_123" }, entry["headers"])
    assert_equal "CGC-2046 platform capabilities", entry["description"]
    assert_equal "http", entry["type"]
    assert_equal "keep me", entry["custom_note"], "条目上的未知额外键必须保留"
    assert_equal({ "type" => "stdio", "command" => "x" }, result[:data]["mcpServers"]["other"])
  end

  # 4. 非法 JSON 输入 → 按空处理（不抛异常）
  def test_upsert_treats_invalid_json_as_empty
    result = Cgc2046McpConfig.upsert_server("{not json", name: "cgc-2046", spec: SPEC)

    assert result[:created]
    assert_equal SPEC, result[:data]["mcpServers"]["cgc-2046"]
  end

  # 4b. 非 Hash 的 JSON（数组/标量）同样按空处理
  def test_upsert_treats_non_object_json_as_empty
    result = Cgc2046McpConfig.upsert_server('["a","b"]', name: "cgc-2046", spec: SPEC)

    assert result[:created]
    assert_equal SPEC, result[:data]["mcpServers"]["cgc-2046"]
  end

  # 5. 输出 pretty JSON 且以 \n 结尾
  def test_to_json_text_is_pretty_and_newline_terminated
    hash = { "mcpServers" => { "cgc-2046" => SPEC } }
    text = Cgc2046McpConfig.to_json_text(hash)

    assert text.end_with?("\n"), "输出必须以换行结尾"
    assert_equal JSON.pretty_generate(hash) + "\n", text
    assert_includes text, "\n  ", "必须是 pretty（带缩进）格式"
  end

  # 6. status_of 返回 configured/url，且结果无 headers/token 泄漏
  def test_status_of_configured
    text = JSON.generate({ "mcpServers" => { "cgc-2046" => SPEC } })
    st = Cgc2046McpConfig.status_of(text, name: "cgc-2046")

    assert_equal true, st[:configured]
    assert_equal "http://localhost:4102/mcp", st[:url]
    refute st.key?(:headers), "status 结果不得含 headers"
    refute st.key?(:token), "status 结果不得含 token"
    refute_includes JSON.generate(st), "tok_secret_123", "status 结果序列化后不得含 token 明文"
    refute_includes JSON.generate(st), "Bearer", "status 结果序列化后不得含 Authorization"
  end

  def test_status_of_unconfigured_when_missing
    st = Cgc2046McpConfig.status_of('{"mcpServers":{}}', name: "cgc-2046")

    assert_equal false, st[:configured]
    assert_nil st[:url]
  end

  def test_status_of_unconfigured_on_invalid_json
    st = Cgc2046McpConfig.status_of("garbage", name: "cgc-2046")

    assert_equal false, st[:configured]
    assert_nil st[:url]
  end

  # 附加：Hash 输入直接可用（json_text_or_hash 双形态）
  def test_upsert_accepts_hash_input_without_mutating_it
    input = { "mcpServers" => { "other" => { "type" => "stdio", "command" => "x" } } }
    frozen_input = JSON.parse(JSON.generate(input))

    result = Cgc2046McpConfig.upsert_server(input, name: "cgc-2046", spec: SPEC)

    assert result[:created]
    assert_equal frozen_input, input, "不得修改调用方传入的 Hash"
    assert_equal SPEC, result[:data]["mcpServers"]["cgc-2046"]
  end

  # ---- persist / load_text（写入加固：原子写 + 0600 + mode 保留）----

  def test_load_text_returns_nil_when_missing
    Dir.mktmpdir do |dir|
      assert_nil Cgc2046McpConfig.load_text(File.join(dir, "mcp.json"))
    end
  end

  def test_load_text_reads_existing_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "mcp.json")
      File.write(path, '{"a":1}')

      assert_equal '{"a":1}', Cgc2046McpConfig.load_text(path)
    end
  end

  def test_persist_creates_new_file_with_mode_0600
    Dir.mktmpdir do |dir|
      path = File.join(dir, "mcp.json")
      Cgc2046McpConfig.persist(path, { "a" => 1 })

      assert_equal JSON.pretty_generate({ "a" => 1 }) + "\n", File.read(path)
      assert_equal 0o600, File.stat(path).mode & 0o777, "新建文件必须 0600（含 token 的敏感配置）"
    end
  end

  def test_persist_preserves_existing_file_mode
    Dir.mktmpdir do |dir|
      path = File.join(dir, "mcp.json")
      File.write(path, "{}")
      File.chmod(0o644, path)

      Cgc2046McpConfig.persist(path, { "a" => 1 })

      assert_equal 0o644, File.stat(path).mode & 0o777, "重写既有文件不得改变原 mode"
    end
  end

  def test_persist_leaves_no_tmp_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "mcp.json")
      Cgc2046McpConfig.persist(path, { "a" => 1 })

      refute File.exist?("#{path}.tmp"), "rename 后不得残留 tmp 文件"
      assert_equal ["mcp.json"], Dir.children(dir), "目录里只应有目标文件"
    end
  end

  def test_persist_creates_parent_dirs
    Dir.mktmpdir do |dir|
      path = File.join(dir, "sub", "dir", "mcp.json")
      Cgc2046McpConfig.persist(path, { "a" => 1 })

      assert File.exist?(path)
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  # ---- B1' 加固：tmp 0600 排他创建 / EXCL 重试 / 失败清理 / persist_text 原文 ----

  def test_persist_text_writes_raw_bytes_verbatim
    Dir.mktmpdir do |dir|
      path = File.join(dir, "mcp.json")
      Cgc2046McpConfig.persist_text(path, "{broken json")

      assert_equal "{broken json", File.read(path), "原文必须逐字节写入（不序列化、不 normalize）"
      assert_equal 0o600, File.stat(path).mode & 0o777
    end
  end

  def test_persist_creates_tmp_excl_with_0600_from_birth
    Dir.mktmpdir do |dir|
      path = File.join(dir, "mcp.json")
      captured = nil
      original = File.method(:open)
      spy = ->(*args, **kw, &blk) { captured ||= args; original.call(*args, **kw, &blk) }
      File.define_singleton_method(:open, &spy)

      begin
        Cgc2046McpConfig.persist(path, { "a" => 1 })
      ensure
        File.define_singleton_method(:open, original)
      end

      refute_nil captured, "persist 必须经 File.open 创建 tmp"
      assert_equal File::WRONLY | File::CREAT | File::EXCL, captured[1], "tmp 必须排他创建"
      assert_equal 0o600, captured[2], "tmp 创建瞬间即 0600"
      assert_match(/\.#{Process.pid}\.[0-9a-f]{8}\.tmp\z/, captured[0], "tmp 名必须含 pid + 随机后缀")
    end
  end

  def test_persist_retries_with_fresh_tmp_name_on_excl_conflict
    Dir.mktmpdir do |dir|
      path = File.join(dir, "mcp.json")
      collide = "#{path}.#{Process.pid}.aaaaaaaa.tmp"
      File.write(collide, "someone else")

      values = %w[aaaaaaaa bbbbbbbb]
      original = SecureRandom.method(:hex)
      SecureRandom.define_singleton_method(:hex) { |_n| values.shift }

      begin
        Cgc2046McpConfig.persist(path, { "a" => 1 })
      ensure
        SecureRandom.define_singleton_method(:hex, original)
      end

      assert_equal JSON.pretty_generate({ "a" => 1 }) + "\n", File.read(path)
      assert_empty values, "EXCL 冲突后应重新生成名字重试一次"
      assert_equal "someone else", File.read(collide), "他人遗留的同名 tmp 不得被覆盖或删除"
    end
  end

  def test_persist_cleans_tmp_when_rename_fails
    Dir.mktmpdir do |dir|
      path = File.join(dir, "mcp.json")
      original = File.method(:rename)
      File.define_singleton_method(:rename) { |*_a| raise Errno::EIO, "io error" }

      begin
        assert_raises(Errno::EIO) { Cgc2046McpConfig.persist(path, { "a" => 1 }) }
      ensure
        File.define_singleton_method(:rename, original)
      end

      assert_empty Dir.children(dir), "失败路径不得残留 tmp 文件"
    end
  end

  # ---- B2''：rename 前 chmod 定稿 tmp（rename 为唯一提交点）+ ensure 清理容错 ----

  def test_persist_chmod_failure_leaves_target_untouched
    Dir.mktmpdir do |dir|
      path = File.join(dir, "mcp.json")
      File.write(path, "original")

      original = File.method(:chmod)
      File.define_singleton_method(:chmod) { |*_a| raise Errno::EPERM, "chmod denied" }
      begin
        assert_raises(Errno::EPERM) { Cgc2046McpConfig.persist(path, { "a" => 1 }) }
      ensure
        File.define_singleton_method(:chmod, original)
      end

      assert_equal "original", File.read(path), "chmod 失败时目标文件不得被触碰（rename 前无提交）"
      assert_empty Dir.children(dir) - ["mcp.json"], "chmod 失败的 tmp 必须被清理"
    end
  end

  def test_persist_cleanup_failure_does_not_mask_rename_error
    Dir.mktmpdir do |dir|
      path = File.join(dir, "mcp.json")

      orig_rename = File.method(:rename)
      orig_delete = File.method(:delete)
      File.define_singleton_method(:rename) { |*_a| raise Errno::EIO, "rename io error" }
      File.define_singleton_method(:delete) { |*_a| raise Errno::EPERM, "delete denied" }
      begin
        err = assert_raises(Errno::EIO) { Cgc2046McpConfig.persist(path, { "a" => 1 }) }
        assert_includes err.message, "rename io error", "上抛的必须是 rename 的原始异常，不得被清理异常覆盖"
      ensure
        File.define_singleton_method(:rename, orig_rename)
        File.define_singleton_method(:delete, orig_delete)
      end
    end
  end

  # ---- remove_server（断开连接：移除 cgc-2046 条目，其它 server 无损）----

  def test_remove_server_removes_cgc_preserving_others
    input = JSON.generate(
      "mcpServers" => {
        "cgc-2046" => SPEC,
        "other" => { "type" => "stdio", "command" => "x" }
      }
    )

    result = Cgc2046McpConfig.remove_server(input, name: "cgc-2046")

    assert result[:removed], "存在 cgc-2046 条目时应移除"
    assert_nil result[:data]["mcpServers"]["cgc-2046"], "cgc-2046 条目必须被移除"
    assert_equal({ "type" => "stdio", "command" => "x" }, result[:data]["mcpServers"]["other"],
                 "其它 server 条目不得受影响")
  end

  def test_remove_server_noop_when_missing
    input = JSON.generate("mcpServers" => { "other" => { "type" => "stdio" } })

    result = Cgc2046McpConfig.remove_server(input, name: "cgc-2046")

    refute result[:removed], "无 cgc-2046 条目时应为 no-op"
    assert_equal({ "other" => { "type" => "stdio" } }, result[:data]["mcpServers"])
    assert_equal JSON.parse(input), result[:data], "内容必须保持不变"
  end

  def test_remove_server_noop_on_empty_config
    result = Cgc2046McpConfig.remove_server("{}", name: "cgc-2046")

    refute result[:removed]
    assert_nil result[:data]["mcpServers"], "no-op 时不得无谓创建 mcpServers 键"
    assert_equal({}, result[:data])
  end

  def test_remove_server_treats_invalid_json_as_empty
    result = Cgc2046McpConfig.remove_server("{broken", name: "cgc-2046")

    refute result[:removed]
    assert_nil result[:data]["mcpServers"]
    assert_equal({}, result[:data])
  end

  def test_remove_server_accepts_hash_input_without_mutating_it
    input = JSON.parse(JSON.generate("mcpServers" => { "cgc-2046" => SPEC, "other" => { "type" => "stdio" } }))
    snapshot = JSON.generate(input)

    result = Cgc2046McpConfig.remove_server(input, name: "cgc-2046")

    assert result[:removed]
    assert_equal snapshot, JSON.generate(input), "不得修改调用方传入的 Hash"
  end

  # ---- status_of 的 token 状态（token_configured，仍不泄漏 token）----

  def test_status_of_reports_token_configured_when_authorization_present
    text = JSON.generate({ "mcpServers" => { "cgc-2046" => SPEC } })
    st = Cgc2046McpConfig.status_of(text, name: "cgc-2046")

    assert_equal true, st[:token_configured]
    assert_equal true, st[:configured]
    refute_includes JSON.generate(st), "tok_secret_123"
    refute_includes JSON.generate(st), "Bearer"
  end

  def test_status_of_token_unconfigured_when_no_headers
    text = JSON.generate("mcpServers" => { "cgc-2046" => { "type" => "http", "url" => "http://x/mcp" } })
    st = Cgc2046McpConfig.status_of(text, name: "cgc-2046")

    assert_equal false, st[:token_configured]
    assert_equal true, st[:configured]
  end

  def test_status_of_token_unconfigured_when_disconnected
    st = Cgc2046McpConfig.status_of('{"mcpServers":{}}', name: "cgc-2046")

    assert_equal false, st[:token_configured]
    assert_equal false, st[:configured]
  end

  # ---- 事务方法（connect_server / disconnect_server）----
  # 测试先行（Phase 0）：方法未实现时此段应因 NoMethodError 失败（红）。
  # reloader 为注入 callable；persist/persist_text 被 stub 记录调用，不真实落盘。

  def test_connect_server_success_persists_once_and_reloads_once
    old = JSON.generate("mcpServers" => { "other" => { "type" => "stdio", "command" => "x" } })

    stub_fs(old_text: old) do |persisted, _restored, reloader|
      result = Cgc2046McpConfig.connect_server(name: "cgc-2046", spec: SPEC, reloader: reloader)

      assert_equal({ created: true }, result)
      assert_equal 1, persisted.size, "应恰好 persist 一次"
      entry = persisted.first[1].dig("mcpServers", "cgc-2046")
      assert_equal "Bearer tok_secret_123", entry.dig("headers", "Authorization"),
                   "token 的唯一去向是 mcp.json 的 headers"
      assert_equal({ "type" => "stdio", "command" => "x" }, persisted.first[1].dig("mcpServers", "other"),
                   "既有 server 条目语义无损")
      assert_equal 1, reloader.count, "写后必须 reload 恰好一次"
    end
  end

  def test_connect_server_existing_entry_returns_created_false
    old = JSON.generate("mcpServers" => { "cgc-2046" => {
      "type" => "http", "url" => "http://old/mcp", "headers" => {}, "custom" => "keep"
    } })

    stub_fs(old_text: old) do |persisted, _restored, reloader|
      result = Cgc2046McpConfig.connect_server(name: "cgc-2046", spec: SPEC, reloader: reloader)

      assert_equal({ created: false }, result)
      assert_equal 1, persisted.size
      entry = persisted.first[1].dig("mcpServers", "cgc-2046")
      assert_equal "keep", entry["custom"], "条目上的未知额外键必须保留"
      assert_equal "Bearer tok_secret_123", entry.dig("headers", "Authorization")
      assert_equal 1, reloader.count
    end
  end

  def test_connect_server_reload_failure_raises_and_rolls_back_raw_text
    old = JSON.generate("mcpServers" => { "other" => { "type" => "stdio", "command" => "x" } })
    reloader = failing_reloader(fail_times: 1)

    stub_fs(old_text: old) do |persisted, restored, _reloader|
      err = assert_raises(RuntimeError) do
        Cgc2046McpConfig.connect_server(name: "cgc-2046", spec: SPEC, reloader: reloader[:fn])
      end
      assert_includes err.message, "reload failed", "必须抛出含 reload failed 的 RuntimeError"

      assert_equal 1, persisted.size, "正向写恰好一次"
      assert_equal 1, restored.size, "回滚写恰好一次"
      assert_equal old, restored.first[1], "回滚必须写回进入时的原文 bytes（禁止 normalize 后重序列化）"
      assert_equal 2, reloader[:count][0], "恢复落盘后必须 best-effort 再 reload 一次"
    end
  end

  def test_disconnect_server_success_removes_and_reloads
    old = JSON.generate("mcpServers" => { "cgc-2046" => {
      "type" => "http", "url" => "http://x/mcp", "headers" => { "Authorization" => "Bearer tok_old" }
    }, "other" => { "type" => "stdio", "command" => "x" } })

    stub_fs(old_text: old) do |persisted, _restored, reloader|
      result = Cgc2046McpConfig.disconnect_server(name: "cgc-2046", reloader: reloader)

      assert_equal({ removed: true }, result)
      assert_equal 1, persisted.size, "应恰好 persist 一次"
      assert_nil persisted.first[1].dig("mcpServers", "cgc-2046"), "cgc-2046 条目必须被移除"
      assert_equal({ "type" => "stdio", "command" => "x" }, persisted.first[1].dig("mcpServers", "other"),
                   "其它 server 条目语义无损")
      assert_equal 1, reloader.count, "写后必须 reload 恰好一次"
    end
  end

  def test_disconnect_server_noop_without_persist_or_reload
    old = JSON.generate("mcpServers" => { "other" => { "type" => "stdio", "command" => "x" } })

    stub_fs(old_text: old) do |persisted, _restored, reloader|
      result = Cgc2046McpConfig.disconnect_server(name: "cgc-2046", reloader: reloader)

      assert_equal({ removed: false }, result)
      assert_empty persisted, "no-op 时不得写盘"
      assert_equal 0, reloader.count, "no-op 时不得 reload"
    end
  end

  def test_disconnect_server_reload_failure_rolls_back_and_reloads_again
    old = JSON.generate("mcpServers" => { "cgc-2046" => {
      "type" => "http", "url" => "http://x/mcp", "headers" => { "Authorization" => "Bearer tok_old" }
    }, "other" => { "type" => "stdio", "command" => "x" } })
    reloader = failing_reloader(fail_times: 1)

    stub_fs(old_text: old) do |persisted, restored, _reloader|
      err = assert_raises(RuntimeError) do
        Cgc2046McpConfig.disconnect_server(name: "cgc-2046", reloader: reloader[:fn])
      end
      assert_includes err.message, "reload failed"

      assert_equal 1, persisted.size, "正向移除写恰好一次"
      assert_equal 1, restored.size, "回滚写恰好一次"
      assert_equal old, restored.first[1], "回滚必须写回进入时的原文 bytes（cgc-2046 条目必须被恢复）"
      assert_equal 2, reloader[:count][0], "恢复落盘后必须 best-effort 再 reload 一次"
    end
  end

  # mutex 决策 3=A：模块级 @write_mutex，事务期间持锁（其它线程被阻塞）
  def test_connect_server_holds_module_write_mutex_during_transaction
    assert_kind_of Mutex, Cgc2046McpConfig.write_mutex, "模块级 write_mutex 必须是 Mutex"
    assert_same Cgc2046McpConfig.write_mutex, Cgc2046McpConfig.write_mutex,
                "write_mutex 必须是模块级单例"

    in_lock = Queue.new
    proceed = Queue.new
    other_entered = false
    reloader = lambda do
      in_lock << true # 通知主测试线程：事务线程已持锁
      proceed.pop     # 阻塞在锁内，等主测试线程完成检测
    end

    stub_fs(old_text: "{}") do |_persisted, _restored, _reloader|
      tx = Thread.new do
        Cgc2046McpConfig.connect_server(name: "cgc-2046", spec: SPEC, reloader: reloader)
      end

      other = Thread.new do
        Cgc2046McpConfig.write_mutex.synchronize { other_entered = true }
      end

      in_lock.pop # 事务线程已进入锁内（reloader 执行中）
      refute other.join(0.1), "事务持锁期间其它线程不得进入临界区"
      other.kill
      other.join
      proceed << true # 放行事务线程完成
      tx.join
    end
  end

  private

  # reloader 计数器（count 穿透闭包），fail_times 控制前 N 次抛错（之后成功）。
  # 返回 { fn:, count: }，count 是单元素数组，事后可断言调用次数。
  def failing_reloader(fail_times:)
    count = [0]
    fn = lambda do
      count[0] += 1
      if fail_times > 0
        fail_times -= 1
        raise "registry boom"
      end
    end
    { fn: fn, count: count }
  end

  # stub config_path/load_text/persist/persist_text（singleton method 重定义，ensure 恢复）。
  # persist 记录序列化写，persist_text 记录原文写；reloader 为可调用 + count 的计数器。
  FakeReloader = Struct.new(:count) do
    def call
      self.count += 1
    end
  end

  def stub_fs(old_text:)
    persisted = []
    restored = []
    reloader = FakeReloader.new(0)
    writer = ->(path, hash) { persisted << [path, hash] }
    raw_writer = ->(path, text) { restored << [path, text] }

    stubs = {
      config_path:  "/fake/home/.clacky/mcp.json",
      load_text:    old_text,
      persist:      writer,
      persist_text: raw_writer
    }
    with_stubs(**stubs) { yield persisted, restored, reloader }
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
end

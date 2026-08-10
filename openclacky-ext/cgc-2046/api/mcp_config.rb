# frozen_string_literal: true

# CGC-2046 扩展：~/.clacky/mcp.json 的 read-merge-write 纯逻辑模块。
#
# 不依赖 clacky gem，可独立单测（见 test/mcp_config_test.rb）。
# 语义对齐 openclacky HttpServer 的 mcp_load_raw_config / mcp_write_raw_config 先例：
#   读（容错为空）→ 改 data["mcpServers"][name] → JSON.pretty_generate + "\n" 写回。
#
# 写入加固：
#   - 原子写：tmp 唯一名（pid + 随机后缀）0600 排他创建，写后 File.rename 覆盖
#     （同目录，POSIX 原子，rename 为唯一提交点），杜绝截断 JSON；
#   - 权限：新建文件 0600（含 token 的敏感配置）；重写既有文件保留原 mode；
#   - tmp 文件在 ensure 中容错清理（best-effort，清理失败不覆盖原始异常）。
#
# 安全红线：status_of 的返回值永不包含 headers / token。

require "json"
require "fileutils"
require "securerandom"

module Cgc2046McpConfig
  # upsert 时允许写入/更新的键（条目上的未知额外键保留）
  ENTRY_KEYS = %w[type url headers description].freeze

  # 模块级写锁：保护 read-merge-write 事务不被本包自身并发打断。
  # 挂在 module 对象上——热加载 reopen 保持同一 module 对象身份，锁实例稳定。
  @write_mutex = Mutex.new

  # @return [Mutex] 模块级写锁单例
  def self.write_mutex
    @write_mutex
  end

  module_function

  # 默认配置文件路径（~/.clacky/mcp.json，运行时解析 Dir.home）
  def config_path
    File.join(Dir.home, ".clacky", "mcp.json")
  end

  # 读取配置原文；文件不存在返回 nil（区别于空内容），读取异常向上抛。
  def load_text(path)
    return nil unless File.exist?(path)

    File.read(path)
  end

  # 原子写入配置（Hash 序列化后委托 persist_text）。
  # @return [String] path
  def persist(path, hash)
    persist_text(path, to_json_text(hash))
  end

  # 原子写入原始文本（回滚等场景逐字节写回，不序列化、不 normalize）：
  #   1. tmp 唯一名（pid + 随机后缀），0600 排他创建（EXCL 防复用遗留文件/symlink，
  #      冲突时重新生成名字重试一次）；
  #   2. 创建后立即把 tmp chmod 为最终 mode（目标原已存在则原 mode，否则 0600）；
  #   3. File.rename 是唯一提交点——之前的任何失败都未触碰目标文件；
  #   4. 任何失败路径 ensure 清理自己的 tmp（清理异常容错，不覆盖原始异常；
  #      不碰他人同名文件）。
  # @return [String] path
  def persist_text(path, text)
    dir = File.dirname(path)
    FileUtils.mkdir_p(dir)

    final_mode = File.exist?(path) ? (File.stat(path).mode & 0o777) : 0o600
    tmp = nil

    begin
      2.times do
        tmp = unique_tmp_path(path)
        begin
          File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |f|
            File.chmod(final_mode, tmp)
            f.write(text)
          end
          break
        rescue Errno::EEXIST
          tmp = nil # 非我创建，不得清理；重新生成名字重试一次
          next
        end
      end
      raise Errno::EEXIST, "cannot allocate unique tmp file for #{path}" if tmp.nil?

      File.rename(tmp, path) # 唯一提交点
      tmp = nil
    ensure
      begin
        File.delete(tmp) if tmp && File.exist?(tmp)
      rescue StandardError
        # 清理失败不得覆盖原始异常
      end
    end

    path
  end

  # 合并写入一个 server 条目。
  #
  # @param json_text_or_hash [String, Hash, nil] mcp.json 原文、已解析的 Hash 或 nil
  # @param name  [String] 条目名（handler 写死 "cgc-2046"，防止 clobber 任意条目）
  # @param spec  [Hash]   完整条目内容（type/url/headers/description 四键）
  # @return [Hash] { data:, created: }
  #   data    — 合并后的完整配置 Hash（string keys，可交 to_json_text 序列化）
  #   created — true 表示新建条目；false 表示更新既有条目（未知额外键已保留）
  #
  # - 无效 JSON / 非 Hash 输入按 {} 处理，不抛异常；
  # - 调用方传入的 Hash 不被修改（内部 JSON round-trip 深拷贝，同时规范化 key 为 String）。
  def upsert_server(json_text_or_hash, name:, spec:)
    data = normalize(json_text_or_hash)
    servers = data["mcpServers"]
    servers = data["mcpServers"] = {} unless servers.is_a?(Hash)

    existing = servers[name]
    created = !servers.key?(name)

    if existing.is_a?(Hash)
      # 已存在：只更新四键，保留该条目上的未知额外键
      spec.each do |key, value|
        existing[key] = value if ENTRY_KEYS.include?(key)
      end
    else
      # 不存在（或既存条目不是 Hash，属畸形数据）：整体新建/替换
      servers[name] = spec.each_key.with_object({}) { |k, acc| acc[k.to_s] = spec[k] }
    end

    { data: data, created: created }
  end

  # 移除一个 server 条目（断开连接）。
  #
  # @param json_text_or_hash [String, Hash, nil] mcp.json 原文、已解析的 Hash 或 nil
  # @param name  [String] 条目名（handler 写死 "cgc-2046"）
  # @return [Hash] { data:, removed: }
  #   data    — 移除后的完整配置 Hash（string keys）
  #   removed — true 表示该条目确实被移除；false 表示本来就不存在（no-op，内容不变）
  #
  # - 无效 JSON / 非 Hash 输入按 {} 处理，不抛异常；
  # - 只动 name 条目，其它 server 条目不受影响；调用方传入的 Hash 不被修改。
  def remove_server(json_text_or_hash, name:)
    data = normalize(json_text_or_hash)
    servers = data["mcpServers"]

    if servers.is_a?(Hash) && servers.key?(name)
      servers.delete(name)
      { data: data, removed: true }
    else
      { data: data, removed: false }
    end
  end

  # 查询条目配置状态。
  #
  # @return [Hash] { configured: bool, url: String|nil, token_configured: bool }
  #   永不返回 headers / token。configured 定义：条目存在且含非空 url；
  #   token_configured 定义：条目 headers 中含非空 Authorization（仅布尔，不泄露值）。
  def status_of(json_text_or_hash, name:)
    data = normalize(json_text_or_hash)
    servers = data["mcpServers"]
    entry = servers.is_a?(Hash) ? servers[name] : nil

    url = entry.is_a?(Hash) ? entry["url"] : nil
    configured = url.is_a?(String) && !url.empty?

    headers = entry.is_a?(Hash) && entry["headers"].is_a?(Hash) ? entry["headers"] : {}
    auth = headers["Authorization"]
    token_configured = auth.is_a?(String) && !auth.empty?

    { configured: configured, url: configured ? url : nil, token_configured: token_configured }
  end

  # 连接事务：独占一次配置变更——snapshot（读进入时原文）→ upsert → 原子提交 →
  # reload；reload 失败时 byte-exact 回滚 + best-effort 二次 reload，再抛异常。
  #
  # @param name      [String] 条目名（handler 写死 "cgc-2046"，防 clobber 任意条目）
  # @param spec      [Hash]   完整条目内容（type/url/headers/description 四键）
  # @param reloader  [Proc]   注入的 registry reload callable（handler 封装宿主私有 registry）
  # @return [Hash] { created: bool }
  # @raise [RuntimeError] reload 失败时抛出（消息含 "mcp registry reload failed"）；
  #   此时落盘已回滚为进入时原文，且已 best-effort 二次 reload
  def connect_server(name:, spec:, reloader:)
    write_mutex.synchronize do
      path = config_path
      old_text = load_text(path)
      merged = upsert_server(old_text, name: name, spec: spec)
      persist(path, merged[:data])

      begin
        reloader.call
      rescue StandardError
        rollback_to(path, old_text)
        safe_reload(reloader)
        raise "mcp registry reload failed"
      end

      { created: merged[:created] }
    end
  end

  # 断开事务：独占一次配置变更——snapshot → remove → 原子提交 → reload；
  # reload 失败时回滚（恢复被移除条目）+ best-effort 二次 reload，再抛异常。
  #
  # @param name      [String] 条目名（handler 写死 "cgc-2046"）
  # @param reloader  [Proc]   注入的 registry reload callable
  # @return [Hash] { removed: bool }（removed:false 时 no-op，不写盘不 reload）
  # @raise [RuntimeError] reload 失败时抛出（消息含 "mcp registry reload failed"）；
  #   此时落盘已回滚（cgc-2046 条目恢复），且已 best-effort 二次 reload
  def disconnect_server(name:, reloader:)
    write_mutex.synchronize do
      path = config_path
      old_text = load_text(path)
      result = remove_server(old_text, name: name)
      return { removed: false } unless result[:removed]

      persist(path, result[:data])

      begin
        reloader.call
      rescue StandardError
        rollback_to(path, old_text)
        safe_reload(reloader)
        raise "mcp registry reload failed"
      end

      { removed: true }
    end
  end

  # @api private
  # byte-exact recovery：old_text 非空逐字节写回（禁止 normalize——非法 JSON 也逐字节
  # 恢复）；为空（旧文件原本不存在）则删掉新建文件。回滚失败不掩盖原始异常。
  def rollback_to(path, old_text)
    if old_text
      persist_text(path, old_text)
    elsif File.exist?(path)
      File.delete(path)
    end
  rescue StandardError
    # 回滚失败不掩盖原始异常
  end

  # @api private
  # best-effort 二次 reload（恢复落盘后把旧配置载回运行时 registry）；失败忽略，
  # 运行时状态待下次 connect/disconnect 重试，不掩盖原始异常。
  def safe_reload(reloader)
    reloader.call
  rescue StandardError
    # 忽略
  end

  # 序列化为 pretty JSON 文本（以 "\n" 结尾），对齐 HttpServer 先例。
  def to_json_text(hash)
    JSON.pretty_generate(hash) + "\n"
  end

  # tmp 唯一名：<path>.<pid>.<8 位随机 hex>.tmp
  def unique_tmp_path(path)
    "#{path}.#{Process.pid}.#{SecureRandom.hex(4)}.tmp"
  end

  # 输入规范化：String 按 JSON 解析（失败按 {}），Hash 深拷贝，nil/其它按 {}。
  # 返回值保证是 String-key 的 Hash。
  def normalize(json_text_or_hash)
    case json_text_or_hash
    when Hash
      JSON.parse(JSON.generate(json_text_or_hash))
    when String
      parsed = JSON.parse(json_text_or_hash)
      parsed.is_a?(Hash) ? parsed : {}
    else
      {}
    end
  rescue JSON::ParserError, JSON::GeneratorError
    {}
  end
end

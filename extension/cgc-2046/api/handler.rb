# frozen_string_literal: true

# CGC-2046 连接器扩展 API handler。
# 挂载前缀 /api/ext/cgc-2046/（由 ApiExtensionDispatcher 自动添加），热加载无需重启。
#
# 安全红线：token 只允许写入 ~/.clacky/mcp.json；任何路径不得把 token
# 写进响应体、日志或 data_path 文件。
#
# 写入加固：类级互斥锁包住「读-merge-写-reload」整段；落盘走
# Cgc2046McpConfig.persist（0600 排他 tmp + 原子 rename）；reload 失败
# best-effort 逐字节回滚旧内容并二次 reload。

require "json"
require "fileutils"
require_relative "mcp_config"

class Cgc2046Ext < Clacky::ApiExtension
  timeout 30

  # 条目名写死，防止 clobber mcp.json 中的任意条目
  SERVER_NAME = "cgc"
  DESCRIPTION = "CGC-2046 platform capabilities"

  # 类级互斥锁：防 handler 自并发的 read-merge-write 竞态。
  # 用惰性 ivar 而非常量——热加载 reopen 同一类对象时保持同一锁实例，且避免重复赋值告警。
  def self.write_mutex
    @write_mutex ||= Mutex.new
  end

  # POST /api/ext/cgc-2046/connect
  # body: { "token": "<必填>", "url": "<可选，缺省读 ext.yml config.mcp_url>" }
  # read-merge-write ~/.clacky/mcp.json 的 mcpServers["cgc"]，然后 reload MCP registry。
  post "/connect" do
    body  = json_body
    token = (body["token"] || body[:token]).to_s.strip

    error!("token is required", status: 422) if token.empty?
    error!("token must be at most 512 characters", status: 422) if token.length > 512

    url = (body["url"] || body[:url]).to_s.strip
    url = config["mcp_url"].to_s.strip if url.empty?
    error!("mcp url is not configured", status: 422) if url.empty?
    error!("mcp url must start with http:// or https://", status: 422) unless url.match?(%r{\Ahttps?://})

    path = Cgc2046McpConfig.config_path

    merged = nil
    self.class.write_mutex.synchronize do
      old_text = Cgc2046McpConfig.load_text(path)

      merged = Cgc2046McpConfig.upsert_server(
        old_text,
        name: SERVER_NAME,
        spec: {
          "type"        => "http",
          "url"         => url,
          "headers"     => { "Authorization" => "Bearer #{token}" },
          "description" => DESCRIPTION
        }
      )
      Cgc2046McpConfig.persist(path, merged[:data])

      begin
        # nil-safe：registry 惰性创建，尚未创建时下次用到会读新文件
        @http_server&.send(:mcp_registry)&.reload
      rescue StandardError
        # best-effort 回滚：进入时的原文 bytes 原样写回（禁止 normalize——非法 JSON
        # 也必须逐字节恢复）；旧文件原本不存在则删掉新建文件。
        begin
          if old_text
            Cgc2046McpConfig.persist_text(path, old_text)
          elsif File.exist?(path)
            File.delete(path)
          end
        rescue StandardError
          # 回滚失败不掩盖原始错误
        end
        # 恢复落盘后再 best-effort reload 一次，把旧配置载回运行时 registry
        begin
          @http_server&.send(:mcp_registry)&.reload
        rescue StandardError
          # 忽略：已创建的 registry 只在显式 reload 时重读配置（不会随请求自动加载），
          # 此处失败后运行时状态未确认，需下次 connect 重试；不掩盖原始错误
        end
        error!("connect failed: mcp registry reload failed", status: 500)
      end
    end

    json(ok: true, created: merged[:created], url: url)
  rescue Clacky::ApiExtension::Halt
    # helper（json/error!）通过 Halt 结束请求，必须放行，否则会被下面的 500 吞掉
    raise
  rescue StandardError => e
    error!("connect failed: #{e.message}", status: 500)
  end

  # GET /api/ext/cgc-2046/status
  # 返回配置状态；绝不返回 headers / token。
  get "/status" do
    text = Cgc2046McpConfig.load_text(Cgc2046McpConfig.config_path)

    st = Cgc2046McpConfig.status_of(text, name: SERVER_NAME)
    json(ok: true, configured: st[:configured], url: st[:url])
  rescue Clacky::ApiExtension::Halt
    raise
  rescue StandardError => e
    error!("status failed: #{e.message}", status: 500)
  end

  # POST /api/ext/cgc-2046/skills/sync
  # 端点骨架（D11 留位）：全量/增量同步在后续切片交付。
  post "/skills/sync" do
    error!("skills sync ships in a later slice", status: 501)
  end
end

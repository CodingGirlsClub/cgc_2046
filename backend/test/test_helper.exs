ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Cgc2046.Repo, :manual)

# U1 预构建（#246）：wechat 运行时动态模块编译（WeChat.build_client →
# Module.create，模块名 = phash2(appid, secret) 全 VM 确定性唯一）在 async
# 测试开始前串行完成并进 :persistent_term 缓存——所有 async 测试恒
# cache-hit，永不并发首建同名模块（并发 Module.create 确定性 CompileError
# "currently being defined"，graphql_sign_in_with_platform + enrollment 曾
# 触发）。:wechat_client_autostart false（test.exs）只管应用启动自动构建，
# 与本显式预构建不冲突（maybe_start 在 test 环境不执行）。
# config 缺失时 fetch 返回 {:error, :wechat_not_configured}——宽容忽略不阻断
# 测试启动；其它异常如实暴露（测试基础设施问题应早爆）。
case Cgc2046.Miniprogram.WechatClient.fetch() do
  {:ok, _module} -> :ok
  {:error, :wechat_not_configured} -> :ok
end

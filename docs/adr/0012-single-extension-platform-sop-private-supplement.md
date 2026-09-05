# ADR-0012：单扩展与平台私有教研增量

- 状态：已接受；生产部署验收待完成。
- 日期：2026-09-05
- 关联：ADR-0001 D10、SOP 平台化与薄壳计划。

## 决策

OpenClacky 保持一个 AGPL-3.0-only 扩展，包含三个 agent。公开基础方法论在平台四角色 playbook 单点维护；客户端保留启动协议、宿主面板和 skill 入口、安全纪律。权限由网站 RBAC 判定。

只有 tutor 私有增量存于 CodingGirlsClub/cgc-playbooks。tutor、owner、admin 可读取完整 tutor playbook，但读取不扩大任何写工具权限。教研 UI 仍为 tutor-only。授权用户能复制收到的内容，本方案不承诺对授权用户保密。

生产构建读取私有 main，将唯一 tutor.md 校验后复制进 release，删除 staging。API 版本追加原始文件 SHA-256 前八位，镜像版本为 `<public SHA>-pb<hash8>`。私有仓库变更须审核，随后从公开 main 手动部署。操作与验收见运维文档。

运行时异常回落公开基础内容；构建时异常阻止部署。开发环境用 CGC_PLAYBOOKS_DIR，test 与 prod 不读取该覆盖。私有正文和设计稿不得进入公开 Git 历史或日志；本地旧分支和 bundle 保留作备份，不推送。公开历史由私有审计工具检查。

## 拒绝方案与生命周期

不拆 learner/tutor 包，不引入客户端 license 或加密分发依赖，不使用生产宿主机挂载，不在本次实施 DB 编辑后台。issue-video 是公开脚手架，随扩展分发。

plan 020 真正实施 DB 化时，一次性导入内容并退役私有 checkout/deploy key，保持单一内容源。

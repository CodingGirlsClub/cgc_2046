# 私有教研 Playbook 部署

## 上线前置

私有仓库 `CodingGirlsClub/cgc-playbooks` 保持私有，按人工约定走 PR、自查或 review 后合并，不直接推 main。当前免费套餐不提供该私有仓库的强制分支保护；不升级套餐，也不将强制保护作为部署前提。维护者仍可绕过人工约定，这是接受的剩余风险。

创建单仓库只读 SSH deploy key，将私钥登记为公开仓库 production environment 的 `CGC_PLAYBOOKS_DEPLOY_KEY` secret。记录密钥维护负责人、轮换日期；轮换时先验证新 key 再撤销旧 key。公开 main 与 production environment 的保护要求不变。

production environment 的 deployment branch rule 必须只允许 main。workflow 的 main/protected 检查是补充，不能代替 environment 限制。TCR namespace 和构建缓存必须私有，首次上线前用无权限身份验证无法拉取。上述外部设置尚须操作人员验收。

## 更新流程

1. 私有 PR review 合并，运行私有审计测试与 `scripts/audit-public-history <公开仓库路径>`，只记录零命中结果。
2. 首次先将包含部署改动的公开 PR 按 develop → main 发布；之后 SOP 单独更新可直接在公开 main 手动触发 Deploy。
3. backend job checkout 私有 main 到 staging，日志只记录私有 commit；校验普通非 symlink、非空白、UTF-8 文件，只复制 tutor.md，删除 staging。
4. 镜像版本为 `<public SHA>-pb<hash8>`；hash 来自未 trim 的原始文件字节，与 API 一致。
5. 用授权 tutor 会话读取生产 playbook，只记录 version，核对与镜像相同的 hash8。检查制品中只有 tutor.md，无私有 README、设计稿、Git 元数据或凭证。

禁止在公开 Actions 日志和 summary 中输出正文，不运行 cat/head/diff tutor.md 或 shell trace。缺 key、checkout 或校验失败会阻止新 backend 部署，旧容器继续服务；修复后重新触发，不绕过增量校验。回滚使用此前完整镜像版本，不能只用公开 SHA。

## 本地与验收状态

### 只构建、不部署

`Verify backend release (no deploy)` 仅手动触发，workflow 必须位于受保护的 public main，继续使用仅允许 main 的 production environment。固定读取 develop 的一次 checkout，并记录实际 public/private commit；不接受任意分支输入。

入口仅需私有仓库读取 key 与镜像拉取凭证，不读取服务器 SSH key 或生产数据库凭证；拉取现有 amd64 deps 镜像，缺失即失败，先等 develop CI 的 deps-image 完成。release 镜像只在临时 runner 构建，不推送，不上传 artifact/cache。容器以默认 app 用户、只读文件系统、禁网及合成配置执行 eval，核对实际 runtime 配置的目录、文件读取、原始字节哈希与 playbook version。此验证不覆盖真实 MCP 授权或生产服务启动。

私有内容进入构建后的详细日志不回显、不上传，失败仅报告阶段；临时文件、镜像和构建缓存最后清理。失败排查不能直接公开日志。

首次安装入口应只将 `.github/workflows/verify-backend-release.yml`、`scripts/verify-release-playbook.exs` 与 `scripts/test/verify_release_playbook_test.exs` 单独评审进入 main，不能为安装入口合并整个 develop。合入 main 本身仍会触发现有 Deploy：合并前必须核实从上一次成功 Deploy 到候选 main 的全部变化没有 backend/web 部署路径；若已有待部署变化，停止合并另行安排。安装后从 main 手动运行验证，通过后才申请正式 develop → main 发布。本地新增入口不等于 GitHub 已执行验收。

开发启动 backend 时设置 `CGC_PLAYBOOKS_DIR` 指向私有 checkout 的 `playbooks/`。不要复制进公开源码。测试使用合成内容。

本地有效增量已有用户 E2E 证据；生产部署、外部权限和制品验收仍待完成。真实 agent 的失败停止、教材确认门、章节重拉、单角色授权及写后面板同步须在验收矩阵分别记录，不能以截图或单元测试代替。

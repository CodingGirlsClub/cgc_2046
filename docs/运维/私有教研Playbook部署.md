# 私有教研 Playbook 部署

## 上线前置

私有仓库 `CodingGirlsClub/cgc-playbooks` 的 main 必须要求 PR review、禁止直推。创建单仓库只读 SSH deploy key，将私钥登记为公开仓库 production environment 的 `CGC_PLAYBOOKS_DEPLOY_KEY` secret。记录密钥维护负责人、轮换日期；轮换时先验证新 key 再撤销旧 key。

production environment 的 deployment branch rule 必须只允许 main。workflow 的 main/protected 检查是补充，不能代替 environment 限制。TCR namespace 和构建缓存必须私有，首次上线前用无权限身份验证无法拉取。上述外部设置尚须操作人员验收。

## 更新流程

1. 私有 PR review 合并，运行私有审计测试与 `scripts/audit-public-history <公开仓库路径>`，只记录零命中结果。
2. 首次先将包含部署改动的公开 PR 按 develop → main 发布；之后 SOP 单独更新可直接在公开 main 手动触发 Deploy。
3. backend job checkout 私有 main 到 staging，日志只记录私有 commit；校验普通非 symlink、非空白、UTF-8 文件，只复制 tutor.md，删除 staging。
4. 镜像版本为 `<public SHA>-pb<hash8>`；hash 来自未 trim 的原始文件字节，与 API 一致。
5. 用授权 tutor 会话读取生产 playbook，只记录 version，核对与镜像相同的 hash8。检查制品中只有 tutor.md，无私有 README、设计稿、Git 元数据或凭证。

禁止在公开 Actions 日志和 summary 中输出正文，不运行 cat/head/diff tutor.md 或 shell trace。缺 key、checkout 或校验失败会阻止新 backend 部署，旧容器继续服务；修复后重新触发，不绕过增量校验。回滚使用此前完整镜像版本，不能只用公开 SHA。

## 本地与验收状态

开发启动 backend 时设置 `CGC_PLAYBOOKS_DIR` 指向私有 checkout 的 `playbooks/`。不要复制进公开源码。测试使用合成内容。

本地有效增量已有用户 E2E 证据；生产部署、外部权限和制品验收仍待完成。真实 agent 的失败停止、教材确认门、章节重拉、单角色授权及写后面板同步须在验收矩阵分别记录，不能以截图或单元测试代替。

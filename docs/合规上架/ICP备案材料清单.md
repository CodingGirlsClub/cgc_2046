# ICP 备案材料清单（小程序 v1 上架前置）

> 状态：**材料清单**（交 human 按清单准备；备案为 human 决策项）
> 前置：微信/抖音/小红书均要求非个人主体；小红书须专业号。

## 一、主体资质

- [ ] 营业执照（非个人主体，统一社会信用代码）
- [ ] 法定代表人身份证正反面
- [ ] 主体负责人联系方式（手机号 + 邮箱）
- [ ] 主体名称与小程序名称一致性的说明（若不一致，准备授权/关联说明）

## 二、小程序基础信息

- [ ] 小程序名称（建议与「CGC」品牌一致；需在平台查重）
- [ ] 小程序简介（服务描述：学习社区活动报名与通知）
- [ ] 服务类目（建议：教育 > 在线教育 / 社区服务类，按各平台类目表核对）
- [ ] 服务区域说明
- [ ] 客服联系方式（必填项，v1 需配置）

## 三、技术材料

- [ ] 已备案域名（GraphQL API 合法域名；现 dev 用 localhost 不可用于上架）
- [ ] HTTPS 证书（API 域名）
- [ ] 各平台 appid/secret（微信 / 抖音 / 小红书）
- [ ] 微信手机号快速验证组件开通（非个人主体，¥0.03/次，每小程序 1000 次免费额度）
- [ ] 微信订阅消息模板 ID ×9（approval_result / approval_reminder / enrollment_submitted / enrollment_completed / speaker_accepted / speaker_completed / payment_succeeded / refund_succeeded / refund_failed）——与 `backend/config/runtime.exs` 的 `WECHAT_MP_TEMPLATE_*` 逐一对应，prod 对这 9 键 `fetch_env!`，缺任一即启动失败
- [ ] 抖音订阅消息模板 ID ×9（键集与微信完全相同，见上行 9 键）——对应 `TT_MP_TEMPLATE_*`，同样 9 键 `fetch_env!` 缺一即启动失败
- [ ] 小红书订阅消息模板 ID ×9（键集与微信完全相同，见上行 9 键）——对应 `XHS_MP_TEMPLATE_*`，同样 9 键 `fetch_env!` 缺一即启动失败
- [ ] learning_stagnation（微信/抖音/小红书）：config.exs 声明此键但 runtime.exs 未注入——prod 缺该 env **不**导致启动失败，学员停滞提醒场景发送时 `:template_not_configured` 静默失败（config.exs↔runtime.exs 键集漂移，收敛见通知配置面后续项）
- [ ] 前端订阅场景 event_reminder（微信/抖音）：模板 ID 经构建期 env 注入（`CGC_WECHAT_TEMPLATE_EVENT_REMINDER` / `CGC_DOUYIN_TEMPLATE_EVENT_REMINDER`，见 `miniprogram/.env.example`）——前端订阅场景专用，后端 config 无此键、`NotificationConsent.grant`（mutation `grant_mini_program_notification_consent`）返回 :template_not_configured（已知跨面漂移，已拍板仅记录）

## 四、合规材料（配合本批隐私指引草案）

- [ ] 隐私政策全文（含手机号用途、个人信息处理规则）——基于 `docs/合规上架/隐私指引草案.md` 完善
- [ ] 用户协议 / 服务协议
- [ ] 个人信息处理规则（PIPL 要求）
- [ ] 若涉及未成年人（社区学习场景）——儿童个人信息保护规则（视类目要求）

## 五、备案流程时间窗（已调研）

- 微信：平台初审 1–2 工作日 + 省管局 1–20 工作日（典型 5–12 天，复杂约 30 天）
- 抖音 / 小红书：同 ICP 备案框架；小红书要求专业号且同一主体最多 2 个小程序

## 六、预算项

- [ ] 手机号授权费（微信 ¥0.03/次；抖音/小红书按平台价目）
- [ ] 域名 + 证书
- [ ] 各平台年审/认证费用（如适用）

> 本清单不阻塞代码（Phase 0–4 已完成）；阻塞的是上架/发布。signoff packet 状态 = pending，交 human 醒后裁定。

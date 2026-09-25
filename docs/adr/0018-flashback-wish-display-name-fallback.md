# ADR-0018：愿望署名缺少展示名时不公开名册全名

> 日期：2026-09-25 ｜ 状态：已接受 ｜ 决策者：维护者（#816 triage 拍板）
> 关联：#816、R17（`docs/plans/2026-09-21-1550-requirements-flashback-voices-wishes-plan.md`）、许愿树 KTD1、ADR-0017。

## 决策

历史档案作者创建愿望时，匿名档的 `Wish.signature` 快照使用 `AlumniProjection.masked_name`；选择「展示名」时只使用主动维护的 `User.display_name`，缺失或空串同样回退遮罩姓。`flashback_people.full_name` 只能作为生成遮罩姓的输入，不能原文写入愿望署名快照。快照创建后不随账号展示名变化而回溯。公开许愿树及其他读取 `Wish.signature` 的面使用这个快照。

ADR-0017 新增的纯账号作者路径不持有历史名册姓名：选「展示名」且账号展示名非空时保存该值，其余情况保存「匿名」。这一路径与历史档案作者的遮罩姓回退形态不同，但共同遵守“无主动设置的展示名就不公开个人全名”的边界。

## 理由与使用面

R17 已确认公开展示名只取用户主动维护的账号展示名；Web 与小程序的署名选项也承诺不涉及法定姓名。名册全名可能是法定名，不能把选择「展示名」解释为同意公开它。此前 `Wishes.build_writer_snapshots/3` 在账号展示名为空时回退名册全名，既违反上述承诺，也与该函数的文档不一致。

`Flashback.SharedCard` 始终使用 `AlumniProjection.masked_name`，`Flashback.Public` 的金句墙 attribution 也使用遮罩名；它们不消费 `Wish.signature`，本决策不改变其独立授权与读面。`AlumniProjection` 的时间长廊名册及 `Wishes.list_public/2` 的成员愿望读面仍使用遮罩名；愿望公开树直接使用创建时的署名快照。历史档案作者无账号展示名时选「展示名」与选匿名同形，这是预期的隐私边界；是否在表单中禁用该选项另议。

拒绝保留名册全名回退：已公开愿望会永久保存可能属于法定名的文本，仅调整前端提示无法保护旧客户端或 API 调用者。此次不修改金句实名授权、表单选择控件或生产存量数据。

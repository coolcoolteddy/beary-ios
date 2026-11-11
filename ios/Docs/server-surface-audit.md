# 服务端探测结果（server-surface-audit）

日期：2026-11-11
方法：未登录请求＋不存在路径做 404 对照。只写实测，不写推测。

## 1. 探测方法

- 不存在路径 `GET /beary/api/zzz_nonexistent_12345` → 404（对照基线）。
- `GET /beary/api/blindbox/open` → 404（该路由只收 POST，GET 404 不代表路由不存在）。
- 判定规则：401 ≠ 404，即路由存在，只是未登录。
- 401 的路由：`GET /blindbox/today`、`/past-self/messages`、`/friends/list`、`/friends/dm/conversations`、`/blocks`、`/notifications`。
- 403 的路由：`POST /entries/:id/pin`、`/unpin`、`/visibility`（路由存在，未登录被拒）。

## 2. 字段对照表（服务端回包 vs iOS 引用数）

iOS 引用数在 origin/main `cd19f91c` 实测；公开列表实测 16 条。

| 服务端字段 | iOS 引用数 | 备注 |
|---|---|---|
| `is_capsule` / `capsule_*` | 0 处 | App 端无胶囊代码 |
| `mailbox_count` | 生产代码 0 处（仅测试 2 处） | 见第 3 节口径纠正 |
| `bookmark_count` | 0 处 | 服务端在发，iOS 未引用 |
| `live_videos` | 9 处 | |
| `pinned_at` | 3 处 | |
| `edit_deadline` | 6 处（生产 5＋测试 1） | |
| `is_locked` | 生产代码 0 处（仅测试 1 处） | 线上实测：公开列表 16/16 全为 `true`；`edit_deadline`＝发布＋15 分钟 |

## 3. mailbox_count 口径纠正

- 不是每篇日记返回，是列表回包顶层一个标量。
- 计算 SQL（已与 `~/workspace/teddy_beary/worker.js` 核对一致）：

```sql
SELECT COUNT(*) as c FROM beary_entries WHERE author_id = ? AND publish_at > ?
```

绑定值为本人 id 与当前时间，即本人未送达的日记数。
- `scope=mailbox` 列表用同一条件（`author_id = ? AND publish_at > ?`）。
- 该计数是旧投递模型遗留；现模型下日记发布即送达，几乎恒为 0。

## 4. 胶囊字段名纠正

- 线上实际字段：`is_capsule`、`capsule_unlock_at`（毫秒戳）、`capsule_district`。
- 文档 `ios/Docs/time-capsule-fields.md` 写的旧名 `capsule_buried`、`capsule_unlock_date` 已错，不要再按旧名对接。
- App 端 capsule 代码为 0 处。

## 5. 结论

- 11 条产品冲突定版里，真正改 iOS 仓库改不到的是 4 条：#4 编辑锁 PUT 守卫、#6 收藏通知、#5 注销删除、#3 私信 7 天留存（均为服务端行为）。
- 门槛 3 导出是 App 端做的，不算在内。

# TODO

初期遗留的功能清单，按"影响 / 工作量"粗略排序。打钩的当作完成，没打的还没做。

## 工具栏占位

- [ ] 导航前进 / 后退（`<` `>`）—— 用户选中 key 的历史栈，下一步要做
- [ ] Read-only mode（锁图标）—— `disabled(true)`，help "Coming soon"
- [ ] Pub/Sub（电波图标）—— `disabled(true)`，help "Coming soon"

## 类型支持

- [x] **Stream 只读视图** —— `StreamEditor` 用 XRANGE/XLEN 渲染 ID + Fields 表（最近的在上）
- [x] **Stream 行操作** —— Table 选中、右键 Copy ID / Copy Fields / Delete（XDEL）、底部 "Add entry…" 打开多 field/value sheet 走 XADD
- [ ] **Stream 单条编辑** —— Redis 流没有 in-place 修改语义；要改只能"删了再 XADD"，UI 没接
- [ ] **Unknown 兜底** —— 仍是 `ContentUnavailableView "Type not supported yet"`（保留即可）

## Inspector 面板

- [x] **String / List / Set 接通** —— 五种类型现在都会写 `session.inspectorTarget`：String 是只读预览（StringEditor 才是写者，避免 dirty 冲突），List 走 LSET，Set 用 SREM+SADD 改名

## Launcher

- [ ] **New Group…** 按钮 disabled —— `Connection` 模型没分组字段；要做需要新引入 `ConnectionGroup` 或给 `Connection` 加 `groupId`
- [ ] **Import…** 实际上有实现（`importConnections()`），但没测过覆盖路径（重复 / 格式错误 / Keychain 部分失败）
- [ ] **Favorite 心形**（DetailView header）—— 当前是纯 `@State`，重启就丢；要持久化得挂到 `AppState` 或 `UserDefaults`

## Preferences

- [x] **干掉死按钮** —— `scanPageSize` / `fontSize` 滑块和 General tab 都移除了；只剩 Connections 列表

## 安全 / 网络

- [ ] **TLS** —— `RedisConnection.Configuration` 没传 tls，`Connection` 模型也没暴露字段
- [ ] **SSH tunnel** —— 完全没做
- [ ] **Cluster / Sentinel** —— 单连接，未考虑 cluster 路由

## Terminal / 命令面板

- [ ] **命令历史回放** —— 终端没接 ↑/↓ 键
- [ ] **自动补全 / 命令提示** —— 没有
- [ ] **多行命令** —— 当前是单行 NSTextField

## Key 浏览 / 编辑

- [x] **文件夹单击 toggle + 持久高亮** —— 用 `DisclosureGroup` 自管 `expandedFolders`；折叠/展开走 List 选中 setter（点行任意位置都覆盖）；视觉高亮用独立 `listSelection` 状态，folder 也能保持选中而不闪回上一个 leaf
- [x] **TTL 编辑 popover** —— meta bar 上的 TTL 改成 popover：数字 + seconds/minutes/hours/days picker，Persist Key / Save 双按钮；无 TTL 显示 "Forever"
- [ ] **批量选择删除 keys** —— 侧边栏 `List(selection:)` 当前是单选 `String?`，需要切到 `Set<String>`
- [ ] **JSON 美化 / 二进制展示** —— `StringEditor` 是纯文本，无格式化、无 hex 视图
- [ ] **List 大数据分页** —— `LRANGE 0 -1` 一次拉完，大 list 会卡（应该按 page 滚动）
- [ ] **Reload 单个 key** —— inspector 写完目前是触发 editor 整表 reload；可以加只刷当前 key 的路径

## 开发辅助

- [x] **Demo 数据填充** —— `+` 菜单 → "Fill Demo Data"。`session.seedDemoData()` 先 SCAN 删 `demo:*` 再种一组涵盖五种类型 + Stream + 一个带 TTL 的 string

## 测试

- [ ] **零单测** —— CLAUDE.md 自己写 "There are no tests yet"
- 优先值得加测试的：
  - `RedisService.tokenize`（终端解析）
  - `RedisService.scan` 游标分页
  - `KeyTreeNode.build`（嵌套折叠 + 单 key 平铺 + `a:b` 同时存在 `a:b:c` 的边界）
  - `seedDemoData` 幂等性（重复执行不会双倍）

## 其它琐碎

- [ ] **Connection 删除确认对话框** —— 当前直接删
- [ ] **窗口尺寸 / split 比例持久化** —— SwiftUI 默认有，但还没核对每个 scene 的恢复行为
- [ ] **Recent connections 快捷键** —— `⌘1 / ⌘2 / …` 之类没接


## UI Bug
1. 连接窗口输入带回车的主机会换行
2. 连接窗口端口宽度太窄

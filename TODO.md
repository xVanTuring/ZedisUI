# TODO

初期遗留的功能清单，按"影响 / 工作量"粗略排序。打钩的当作完成，没打的还没做。

## 工具栏占位

- [ ] 导航前进 / 后退（`<` `>`）—— 目前是空 closure，需要先定义 navigation history 概念
- [ ] Read-only mode（锁图标）—— `disabled(true)`，help "Coming soon"
- [ ] Pub/Sub（电波图标）—— `disabled(true)`，help "Coming soon"

## 类型支持

- [ ] **Stream** 编辑器 —— `DetailView` 当前回退到 "Type not supported yet"。先做只读 `XRANGE` 视图够用
- [ ] **Unknown** 兜底（目前会落到同一个 `ContentUnavailableView`，可保持）

## Inspector 面板

- [ ] **String / List / Set 没接通** —— 三个 editor 选中行时不写 `session.inspectorTarget`。Hash / ZSet 已经做了，套同一个模式：在 `.onChange(of: selection)` 里 push 一个 `InspectorTarget`，给 `Kind` 加 `.string` / `.listIndex` / `.setMember`

## Launcher

- [ ] **New Group…** 按钮 disabled —— `Connection` 模型没分组字段；要做需要新引入 `ConnectionGroup` 或给 `Connection` 加 `groupId`
- [ ] **Import…** 实际上有实现（`importConnections()`），但没测过覆盖路径（重复 / 格式错误 / Keychain 部分失败）
- [ ] **Favorite 心形**（DetailView header）—— 当前是纯 `@State`，重启就丢；要持久化得挂到 `AppState` 或 `UserDefaults`

## Preferences（误导性占位）

- [ ] `ZedisUI.scanPageSize` —— 写进 `@AppStorage` 但 `RedisService.scan` 写死 `count: 200`，从来没读过
- [ ] `ZedisUI.fontSize` —— 同上，editors 都是系统字体
- 二选一：要么接通，要么从 UI 里移掉这两个滑块，免得用户以为能调

## 安全 / 网络

- [ ] **TLS** —— `RedisConnection.Configuration` 没传 tls，`Connection` 模型也没暴露字段
- [ ] **SSH tunnel** —— 完全没做
- [ ] **Cluster / Sentinel** —— 单连接，未考虑 cluster 路由

## Terminal / 命令面板

- [ ] **命令历史回放** —— 终端没接 ↑/↓ 键
- [ ] **自动补全 / 命令提示** —— 没有
- [ ] **多行命令** —— 当前是单行 NSTextField

## Key 浏览 / 编辑

- [ ] **批量选择删除 keys** —— 侧边栏 `List(selection:)` 当前是单选 `String?`，需要切到 `Set<String>`
- [ ] **JSON 美化 / 二进制展示** —— `StringEditor` 是纯文本，无格式化、无 hex 视图
- [ ] **List 大数据分页** —— `LRANGE 0 -1` 一次拉完，大 list 会卡（应该按 page 滚动）
- [ ] **Reload 单个 key** —— inspector 写完目前是触发 editor 整表 reload；可以加只刷当前 key 的路径

## 测试

- [ ] **零单测** —— CLAUDE.md 自己写 "There are no tests yet"
- 优先值得加测试的：
  - `RedisService.tokenize`（终端解析）
  - `RedisService.scan` 游标分页
  - `KeyTreeNode.build`（嵌套折叠 + 单 key 平铺 + `a:b` 同时存在 `a:b:c` 的边界）

## 其它琐碎

- [ ] **Connection 删除确认对话框** —— 当前直接删
- [ ] **窗口尺寸 / split 比例持久化** —— SwiftUI 默认有，但还没核对每个 scene 的恢复行为
- [ ] **Recent connections 快捷键** —— `⌘1 / ⌘2 / …` 之类没接

# 拒绝与报错的应对

## 网关的拒绝(以「aibox」开头,或说明了 aibox 的规则)

| 信息里有 | 原因 | 怎么办 |
|---|---|---|
| 还没有授权 / 本会话还没有授权 | 这个应用没批准,或者是别的会话批准的 | `request_access` 申请 |
| 禁止控制这类应用 | 终端、IDE、浏览器、访达等在禁止清单里 | 不要重试,换路线:命令用自己的 shell,网页用无头浏览器,文件直接读写;实在需要就告诉用户自己操作 |
| 找不到这个应用 | 名字不对,或者应用不在 `/Applications` 和系统目录里 | 换中文名、英文名或 bundle id 再试;装在别处的应用用不了,告诉用户 |
| 用户拒绝或没有回应 | 确认框被拒绝,或 2 分钟内没人点 | 告诉用户需要批准,不要反复申请 |
| 不是网关读到过的元素 | `element_token` 不是读出来的,或者那一行被 `query` 过滤掉了 | 不带 `query` 重新 `get_window_state`,用新的 token |
| 必须带 pid | 动作没有落到具体窗口上 | 带上 `pid`;用 `element_token` 时先 `get_window_state` |
| 菜单请用 invoke_menu / 不能按名字定位菜单 | 想用 token 或名字点菜单项 | 改用 `invoke_menu(path=[...])` |
| 禁止使用苹果菜单 / 「服务」菜单 | 系统级菜单 | 不要绕;这类事交给用户 |
| 不开放前台模式 | 后台送不进去的输入 | 换键盘、菜单或坐标;都不行就告诉用户这个应用目前控制不了 |
| 不开放这个快捷键 / ⇧⌘ 组合键 | 系统级快捷键、⌘V、可能是「服务」的组合 | 找菜单里的对应项,用 `invoke_menu` |
| 不接受参数 xxx | 参数不在白名单里(驱动的工具说明里有,但 aibox 不开放) | 去掉这个参数;看 SKILL.md 的「aibox 下用不了的东西」 |
| 坐标必须是不小于 0 的窗口内像素坐标 | 坐标是负数,或者在窗口外 | 用截图里的坐标 |
| 驱动已重启或退出,请重试 | 授权变化让驱动重启了 | 重新 `get_window_state`,再做一次 |
| Mac 应用控制当前不可用 | 网关没装、已急停或连不上 | 告诉用户在 Mac 上运行 `aibox cu status`(急停了就 `aibox cu on`) |

## 驱动的回复

| 信息里有 | 意思 | 怎么办 |
|---|---|---|
| `effect:"unverifiable"` / `not driver-verified` | 动作已发出,驱动没法确认有没有生效 | 截图或读差异来确认;不要直接重复,开关类控件按两次就回到原状 |
| `Posted click ... the hardware pointer was not moved` | 后台像素点击。有些应用按真实鼠标位置响应,点击可能落空 | 等 1~2 秒再截图;确实没反应就换键盘或菜单 |
| `background_unavailable` | 这个输入途径在后台不可用,但任务并没有失败 | 改按元素操作,或用 `invoke_menu` |
| `no_focused_text_input` | 窗口当前的焦点不是输入框 | 带上输入框的 `element_token`,或者给 `x, y` 先点中它 |
| `-25200` / `-25205` / `-25206` | 应用可能已经执行了,却仍然报错 | 先重读再决定是否重试 |
| `stale` / `invalidated_snapshot_ids` | token 来自旧的快照 | 用最新一次读取的 token |
| `path segment ... is disabled while the app is in the background` | 这个菜单项在后台被禁用 | 换路线;不要尝试前台 |
| `window_id_not_found` / 窗口列表为空 | 应用刚启动,窗口还没出来;或者窗口已经关了 | 等 1 秒再 `list_windows(pid=...)` |
| `bounded_resource_outside_manifest` | 驱动层面不允许(目标不在授权范围内) | 检查 pid 是不是授权过的应用 |

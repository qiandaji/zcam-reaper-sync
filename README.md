# Reaper + ZCam E2 录制联动

让 Reaper 开始/停止录音时，自动通过 ZCam 的 HTTP API 控制一台或多台 ZCam E2 开始/停止录像；Reaper 里每台相机一行显示录制状态和剩余可录时长（HH:MM）；另有一个只做画面监看的网页，可同时监看多台并自动排布画面。

## 功能
- 录制联动：Reaper 录音键按下/停止，所有 ZCam E2 自动开始/停止录像（监听 `GetPlayState()` 录音位）。
- 多机状态浮窗：每台相机一行，实时显示状态（REC / STANDBY / PLAYBACK / BUSY 等）、IP、剩余可录时长（HH:MM）。
- 会话管理：逐台自动占用/释放 ZCam 独占控制会话，被其他客户端抢占后每 10 秒自动夺回。
- 网页监看：纯 MJPEG 画面监看，输入一个或多个 IP 即看，多台自动排成网格，不占控制会话、不影响录制，附 RTSP 地址复制。
- IP 运行时询问：每次启动弹窗输入相机 IP（多台用逗号分隔），自动记住上次值（REAPER ExtState），无需改脚本。

## 文件
- `zcam_record_sync.lua` — Reaper 后台脚本（ReaScript）：录制联动 + 状态小窗（含剩余可录时长）
- `monitor.html` — 网页监看（仅画面，直接双击打开）

## 原理
- Reaper 侧：后台 Lua 脚本轮询 `reaper.GetPlayState()`，当「正在录音」位（bit 4，即 `&4`）发生变化时触发动作。
- ZCam 侧：官方 HTTP API（E2/protocol/http）：
  - `GET /info` — 查看相机信息（含 eth_ip），可用于测试连通
  - `GET /ctrl/session?action=occupy` — 取得控制权（多数 /ctrl/* 命令需要）
  - `GET /ctrl/rec?action=start` — 开始录像
  - `GET /ctrl/rec?action=stop` — 停止录像
  - `GET /ctrl/mode?action=query` — 查询当前工作状态（rec / rec_ing / rec_paused / pb …）
  - `GET /ctrl/rec?action=remain` — 查询剩余可录时间（分钟，状态窗里显示为 HH:MM）
  - `GET /ctrl/session?action=quit` — 释放控制权

## 状态小窗
脚本运行后会出现一个浮动小窗「ZCam E2」，每台相机一行：状态点 + 状态 + IP + 剩余可录（HH:MM），小窗高度随相机台数自动增加。
- 红点 `REC` — 相机正在录像（rec_ing）
- 黄点 `REC PAUSED` — 相机录像暂停（rec_paused）
- 绿点 `STANDBY` — 相机待机（rec）
- 蓝字 `PLAYBACK` — 相机处于回放模式
- 橙字 `BUSY` — 有别的客户端（ZCam App / 相机网页 UI）占着该相机的控制权
- 灰字 `NO RESP` — Reaper 没能调用 curl（或命令被拦截）
- 灰字 `ERR` — 相机返回了异常内容
- 每行末尾 `剩HH:MM` — 存储卡还能录多久（`/ctrl/rec?action=remain` 的分钟数，每 5 秒刷新一次；取不到时显示 `剩--:--`）

状态轮询采用逐台轮转：在线的相机约 0.7 秒刷新一次，离线的自动降到约 4 秒一次，一台相机掉线不会拖慢其他相机。
关闭该小窗（或在小窗里按 Esc）即停止整个脚本。
如果不想要状态窗，把脚本里 `SHOW_STATUS_WINDOW` 改为 `false`（只保留录制联动）。

## 网页监看（仅画面）
网页只做画面监看，不显示参数、不需要本地服务器：

1. 双击 `monitor.html` 直接在浏览器打开。
2. 顶栏输入相机 IP（多台用逗号、空格或换行分隔）→ 点「连接」。
3. 所有相机画面自动排成网格（1 台满屏、2 台并排、3~4 台两列、5~9 台三列……），某台离线只在该格显示红色「离线」标记，不影响其他画面。

说明：
- 网页只拉 MJPEG 画面流，不碰相机的 /ctrl/* 控制会话，不会和 Reaper 抢控制权。
- 监看走相机的 Stream1（网络推流），录像走 Stream0（文件录制），互不影响（保持相机默认设置即可）。
- 多路同时监看占用带宽较大（每路 MJPEG 约几 Mbps），建议电脑与相机走有线网络，画面卡顿时减少同时监看的台数。

## 步骤 1：把 ZCam 连到电脑所在网络
ZCam E2 以太网支持三种模式（相机菜单 Network 里设置）：
- **Router 模式**（推荐，相机作为 DHCP 客户端接入路由器）：相机和电脑都连同一路由器，在相机网络页或 ZCam App 里查看分配到的 IP。
- **Direct 模式**：相机自己当 DHCP 服务器，固定 IP `10.98.32.1`；用网线直连电脑后，在脚本弹窗里输入 `10.98.32.1`。
- **Static 模式**：手动指定 IP。

## 步骤 2：先在浏览器里测试相机控制
在电脑浏览器（与相机同网）访问（多台相机请对每台分别测试）：

1. `http://<相机IP>/info` → 返回 JSON（含 eth_ip）即连通
2. `http://<相机IP>/ctrl/rec?action=start` → 相机开始录像
3. `http://<相机IP>/ctrl/mode?action=query` → 返回 `{"msg":"rec_ing",...}` 表示正在录
4. `http://<相机IP>/ctrl/rec?action=stop` → 相机停止录像

如果 start/stop 无效，先访问一次 `http://<相机IP>/ctrl/session?action=occupy` 再试。
注意：手机上的 ZCam App 若正连接相机可能占用控制权，测试前先退出 App。

## 步骤 3：在 Reaper 里加载脚本
1. （无需改 .lua）运行时会先弹窗询问相机 IP，多台用逗号分隔（如 `192.168.1.100,192.168.1.101`），自动带出上次填的值；回车确认后脚本才启动。
2. 把脚本放到 Reaper Scripts 目录（可选，方便管理）：
   - macOS: `~/Library/Application Support/REAPER/Scripts/`
   - Windows: `%APPDATA%\REAPER\Scripts\`
3. Reaper 菜单：`Actions > Show action list`（动作列表）。
4. 点 `New action...` → `Load ReaScript...` → 选择该 .lua 文件。
5. 在动作列表里选中它，点 `Run`。脚本会在后台常驻，并弹出状态小窗。

## 使用
- 正常按 Reaper 的录音键即可：Reaper 开始录音 → 所有 ZCam 自动开始录像；Reaper 停止 → 所有 ZCam 自动停止。
- Reaper 录音中按「暂停」时 ZCam 会继续录（走带状态仍处于录音位）。
- 状态小窗逐台显示相机是否在录（REC / STANDBY / PLAYBACK / BUSY），以及剩余可录时长（HH:MM）。
- 关闭状态小窗 = 停止脚本；退出 Reaper 或手动关闭脚本后，脚本会自动释放相机控制权。

## 手动兜底
任何时候都可以用浏览器访问下面地址手动控制/查看相机：
- 开始：`http://<相机IP>/ctrl/rec?action=start`
- 停止：`http://<相机IP>/ctrl/rec?action=stop`
- 状态：`http://<相机IP>/ctrl/mode?action=query`

## 多设备同时访问
- **纯画面监看不影响**：用 RTSP（`rtsp://<相机IP>/live_stream`）、MJPEG 或浏览器预览看画面，不占用 /ctrl/* 控制会话，Reaper 的控制和状态指示不受影响。监看走相机的 Stream1（网络推流），录像走 Stream0（文件录制），两者互不影响——除非在相机设置里把推流源改成 Stream0（那样才会和录像冲突）；保持默认设置即可。
- **不要用监看端去控制相机**：ZCam 的控制会话（session）是独占的。如果另一台电脑用相机网页 UI / ZCam App 点按钮控制，会占用会话，可能让 Reaper 侧命令失败。脚本已在每次录制命令前和状态查询失败时自动重新占用会话，把控制权拿回来。
- 建议监看端只拉流、不操作；需要用 ZCam App 调参时，调完退出 App，让 Reaper 保持控制权。

## 部署 / 更新
- 从 GitHub Release 下载 `zcam-reaper-sync-vX.Y.Z.zip`，解压后按上面「步骤 3」加载 `.lua` 即可；更新时替换 `.lua` 与 `monitor.html` 两个文件。
- 相机 IP 列表存在 REAPER ExtState（`zcam_record_sync/camera_ips`，旧版单机键 `camera_ip` 也兼容），升级不会丢。

## 常见问题
- **start/stop 没反应**：先看状态窗显示什么——`BUSY 会话被占用`＝有别的客户端占着控制权，全部退出后再试；`NO RESP curl失败`＝curl 没跑起来；`ERR ...`＝相机返回了异常内容。确认相机处于录像模式（必要时访问 `/ctrl/mode?action=to_rec`）。
- **状态窗一直显示 BUSY 会话被占用**：关闭手机 ZCam App、关掉浏览器里打开的相机网页 UI 标签页；脚本每 10 秒会自动重新抢占会话，抢到后恢复显示录制状态。
- **状态窗一直显示 OFFLINE/NO RESP**：浏览器先打开 `http://<相机IP>/ctrl/mode?action=query` 测试——能返回 JSON 说明相机和网络正常，问题在 Reaper 侧 curl；不能返回则检查 IP 与网络模式。
- **多台相机中只有一台不录**：先看状态窗那一台是否 `BUSY`（被别的客户端占会话）或 `NO RESP`（IP 不通）；脚本对其他相机的控制不受影响。
- **脚本开机自动运行（可选）**：安装 SWS 扩展后，在 `Extensions > Startup actions` 或使用 SWS Global startup action 把该脚本设为启动动作。
- **Windows 上 curl 不存在**：Windows 10 1803+ 自带 `curl.exe`；更老的系统需手动安装 curl 或用全路径。

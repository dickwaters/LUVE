# LUVE · macOS 上的 Steam 游戏启动器

给 Apple Silicon Mac 用的 **Wine + D3DMetal 游戏环境**，自带应用库、商店浏览器和下载目录。
装好之后，Steam 里买什么、装什么，LUVE就自动列出来，点一下就玩。

> 本包**不包含** Steam 客户端、任何游戏、任何账号信息。Steam 需要你自己登录安装。
> **禁止商用**：里面的 Apple D3DMetal 只允许非商业分发（见 `licenses/`）。

## 安装

1. 把整个文件夹拖到「应用程序」以外的地方（比如 `~/Downloads`）
2. 打开「终端」，cd 进去，运行：

```bash
./install.sh
```

3. 装好后打开 `~/Applications/LUVE.app`

要求：Apple Silicon（M1 及以上）+ macOS 14 以上。首次安装需要联网。

第一次打开如果提示「无法验证开发者」：右键 → 打开 → 再点「打开」。

## 第一次使用

1. 左侧「商店」→ 点一下地址栏旁边的刷新，进 Steam 官网
2. 装好 Steam 后，用**你自己的账号**登录
3. 在 Steam 里买/装游戏
4. 回到「设置」→「重新扫描游戏」，库里就出现了
5. 双击封面就开始玩

## 更新

「设置」→「检查更新」。更新只替换程序和脚本，**不会动你的 Steam 账号、游戏和存档**。

没配置更新源时会提示未配置 —— 那是正常的，等你的分享源上线就行。

## 它替你处理了哪些坑

| 坑 | 处理方式 |
|---|---|
| 游戏秒退（`SteamApi_Init` 返回 false） | 启动前自动补 `steam_appid.txt` |
| 分辨率不对 / 画面被裁 | 虚拟桌面 = 当前屏幕分辨率，不写死 |
| 游戏自己改回奇怪的分辨率 | 启动器按配方在启动前钉死 |
| Steam 没起就点游戏 | 自动拉起 Steam 并等登录成功 |
| 窗口偏移导致点不准 | 虚拟桌面满屏、原点 (0,0) |

16:9 的游戏在 16:10 屏幕上**上下有黑边是正常的**，这是等比不裁切的结果。

## 目录说明

| 路径 | 内容 |
|---|---|
| `~/Library/Application Support/SteamWine/` | 程序、Wine 环境、Steam |
| `.../downloads/` | 内置浏览器的下载目录 |
| `.../recipes/` | 每个游戏的启动配方 |
| `~/Applications/LUVE.app` | 前端 |

卸载：删掉上面这两个路径即可，不留残留。

## 给维护者

```bash
./app/build-app.sh     # 只重编前端
./build.sh             # 打完整包（会剔除 prefix / 账号 / 游戏）
```

`build.sh` 最后会自检，包里一旦混进 `prefix`、`steamapps`、`*.acf`、`playtime.json`、日志或
`steam_appid.txt`，直接报错退出。

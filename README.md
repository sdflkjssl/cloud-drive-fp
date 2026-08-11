# cloud-drive-fp

将任意网盘以**原生占位符文件系统**挂载到桌面的开源方案：打开文件夹才列出内容、打开文件才下载、状态持久、不依赖挂载。

```
[存储层] 夸克 / 百度 / 阿里 / 115 / WebDAV ...
             │  AList（多存储聚合，WebDAV 输出）
[桥层]   alist-bridge.js（Node，平台无关）
             │  统一 WebDAV + /dav/.id/<id> 身份契约
[前端层] macOS：FileProvider 扩展（Swift，本仓库已实现）
         Windows：Cloud Files API 同步引擎（未来，复用同一桥）
```

## 与网盘解耦

桥层只面向 **AList 的 WebDAV**，对具体网盘无感知。支持新网盘 = 在 AList 里添加对应存储：

```bash
# 例：添加百度网盘存储（AList 后台或 API），挂载到 /baidu
# 然后把桥指向该存储：
node app/server/alist-bridge.js --port 8081 --root /baidu
```

| 网盘 | AList 驱动 | 备注 |
|---|---|---|
| 夸克 | Quark | 本仓库默认（`--root /quark`） |
| 百度 | Baidu | 同一 AList 实例，改 `--root` 即可 |
| 阿里云盘 | Ali | 同上 |
| 任意 WebDAV | WebDAV | 同上 |

## 与平台解耦

桥层与前端严格分离，前端只认 `/dav/.id/<id>` 契约：

- **macOS（已实现）**：FileProvider 扩展（`app/Extension`），系统托管、状态持久
- **Windows（规划）**：Cloud Files API（CFAPI）同步引擎——占位符 1KB、打开自动水合，与 FileProvider 行为一致
  - 参考实现：[pure01fx/cfapi](https://github.com/pure01fx/cfapi)（C#）、[Microsoft CFAPI 文档](https://learn.microsoft.com/en-us/windows/win32/cfapi/build-a-cloud-file-sync-engine)
  - 复用本仓库桥层与身份契约，只需实现 CFAPI 前端
- 其他平台（Linux）：rclone mount / WebDAV 挂载（无占位符，可作降级）

## 目录

| 路径 | 说明 |
|---|---|
| `app/Extension` `app/App` | macOS FileProvider 扩展 + 宿主 App（基于 [plinth](https://github.com/ytomasch/plinth)，MIT） |
| `app/server/alist-bridge.js` | 适配桥：`/dav/.id/<id>` 契约 → AList WebDAV，自管 id↔路径映射（持久化） |
| `app/server/plinth-server.js` | 参考后端（本地文件系统版，契约验证用，平台无关） |
| `scripts/` | 运维脚本（AList 配置/状态/按需下载） |
| `scripts/launchd/` | macOS launchd 配置（AList、适配桥） |

## 部署（macOS）

### 1. 依赖

```bash
brew install rclone xcodegen node
```

### 2. 替换占位符（重要，必做）

仓库内的 launchd 模板含占位符，**不替换直接 load 会失败**：

```bash
# <USER>  → 你的用户名（whoami 查看）
# <DATA_DIR> → 数据目录（AList 配置/日志/凭据所在，建议 ~/cloud-drive-data）
sed -i '' \
  -e 's|<USER>|'$(whoami)'|g' \
  -e 's|<DATA_DIR>|'$HOME'/cloud-drive-data|g' \
  scripts/launchd/com.local.alist.plist \
  app/launchd/com.local.quark-fp-bridge.plist
```

也可以不用 launchd，直接带环境变量运行桥（`FP_DATA_DIR` 覆盖数据目录）：

```bash
FP_DATA_DIR=$HOME/cloud-drive-data node app/server/alist-bridge.js \
  --port 8081 --alist http://127.0.0.1:5244 --root /quark
```

### 3. AList（任意网盘存储）

```bash
cp scripts/launchd/com.local.alist.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.local.alist.plist
./scripts/setup-quark.sh   # 配置夸克 cookie（其他网盘用 AList 后台添加存储）
# 存储的 webdav_policy 必须为 native_proxy
```

### 4. 适配桥

```bash
cp app/launchd/com.local.quark-fp-bridge.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/com.local.quark-fp-bridge.plist
# 桥参数: --port 8081 --alist http://127.0.0.1:5244 --root /quark
# 桥从数据目录读取凭据文件（默认 `<仓库父目录>/quark-sync/`，可用环境变量 `FP_DATA_DIR` 指定）
```

### 5. 构建 App（macOS，需 Xcode + Apple ID 免费签名）

```bash
cd app
# Config/Local.xcconfig 设 DEVELOPMENT_TEAM（或 xcodebuild 传参）
xcodegen generate
xcodebuild -project Plinth.xcodeproj -scheme Plinth -configuration Release \
  -allowProvisioningUpdates build
cp -R <DerivedData>/Build/Products/Release/Plinth.app /Applications/
open /Applications/Plinth.app
# App 里填 Server = http://127.0.0.1:8081/dav, Account/Password 任意非空 → Connect
```

Finder 侧边栏 **Locations** 出现盘。

## 桥的身份契约（平台前端实现者必读）

桥对任意前端提供：

```
PROPFIND /dav/               根容器（Depth 1 列全部顶层）
PROPFIND /dav/.id/<id>       stat 单项（Depth 0）或列目录（Depth 1）
GET      /dav/.id/<id>       下载内容（支持 Range）
PUT      /dav/.id/<parent>/<name>  创建/覆盖
MKCOL    /dav/.id/<parent>/<name>  建目录
MOVE     /dav/.id/<id>       移动/重命名（Destination 指向 .id 形式）
DELETE   /dav/.id/<id>       删除
```

- **id 稳定**：桥自管 id↔路径映射（持久化 `fp-idmap.json`），重命名/移动后 id 不变，删除重建后 id 变（FileProvider/CFAPI 均要求此语义）
- **认证**：Basic（任意非空凭据），桥内部用 AList 密码访问 WebDAV，无 token/会话
- PROPFIND 响应含 `fileid` / `parentid` / `getetag`（etag 即内容版本）

## 排障（macOS）

- 图标"云+感叹号"：查 `fp-bridge.log`；枚举能力变化后 bump `app/App/DriveDomain.swift` 的 `schemaVersion` 并重装 App
- 盘消失：确认 AList(:5244) 与桥(:8081) 运行，`launchctl list | grep quark`
- FileProvider 缓存：`killall fileproviderd`
- 扩展日志：`log show --last 5m --predicate 'process == "PlinthFileProvider"'`

## 许可

MIT（plinth 原作者 ytomasch，见 `app/LICENSE`）

## 安全说明

- 桥层（`alist-bridge.js`）监听 `127.0.0.1`，不接受外部连接；若需跨机访问请置于可信网络并自行加认证/隧道。
- App 的 Account/Password 为占位凭据（桥接受任意非空值）；真实凭据（AList 密码）由桥本地读取，不经过 App/扩展。
- FileProvider 扩展沙盒运行，仅访问桥的本地端口与其 App Group 容器。

## 项目状态

- **实验性（alpha）**：macOS 端已在真实环境验证（枚举/下载/移动/删除/占位符），但未经大规模测试；Windows 端未实现。
- 已知限制：下载带宽受网盘第三方渠道限速；FileProvider 图标状态（badge/decoration）尚未实现（见 Roadmap）。
- 欢迎 Issue 与 PR。

## Roadmap

- [x] macOS FileProvider 占位符盘（夸克，经 AList）
- [x] 桥层通用化（任意 AList 存储：百度/阿里/WebDAV）
- [ ] Windows Cloud Files API 前端（复用桥层）
- [ ] 已下载/同步状态图标（OneDrive 式对勾，NSFileProviderItemDecoration）
- [ ] 双向同步/冲突处理（当前为按需读 + 直写）

## 贡献

1. Fork 并提交 PR
2. 修改前先开 Issue 讨论（尤其涉及 FileProvider 框架行为的改动）
3. 保持桥层平台无关（`app/server/` 不引入 macOS 依赖）
4. 新增网盘 = 在 AList 加存储即可；新增平台 = 实现 `/dav/.id/<id>` 契约的前端

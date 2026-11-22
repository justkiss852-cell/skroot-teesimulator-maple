# TEESimulator-RS MapleSU → SKRoot(Pro) 模块

把 **TEESimulator-RS_MapleSU 6.0.32（KernelSU 脚本模块）** 移植成 **SKRoot(Pro) 原生模块**（`.so` + ZIP）。
核心文件（classes.dex / inject / supervisor / libTEESimulator.so / service.sh / core/webui.sh）**原样保留**，
只重写了"谁来启动它"和"WebUI 怎么和后端通信"这两层。

## 为什么不能直接把 KSU 的 zip 装进 SKRoot

| | KernelSU/Magisk 模块 | SKRoot(Pro) 模块 |
|---|---|---|
| 形态 | zip + module.prop + 脚本 | 一个 `.so`（dlopen 加载） |
| 启动时机 | post-fs-data / service 阶段由管理器跑脚本 | zygote64 **之前**加载 `.so`，调 `skroot_module_main()` |
| 文件位置 | `/data/adb/modules/<id>` | 模块私有目录（zip 内容自动释放，0777） |
| WebUI | 管理器 iframe + `ksu.exec` 跑 `core/webui.sh` | `.so` 内 CivetWeb，自己处理 GET/POST |
| SELinux | `sepolicy.rule` 由管理器注入 | 规则不会自动注入（见下文限制） |

## 本移植做了什么

1. **启动链**：`skroot_module_main()` 只做自检 + `fork`；子进程等 `sys.boot_completed=1`
   后执行原版 `service.sh`（它会拉起 `supervisor → daemon`，注入 keystore2，并跑开机 extras）。
   日志：`/data/adb/tricky_store/skroot_boot.log`（脚本输出）与 `skroot_module.log`（.so 输出）。
2. **WebUI 桥**：MapleSU 前端在 "Ultra 形态"下是用 `POST fetch` 访问 `.so` 的端点的。
   这里把每个端点映射成 `sh core/webui.sh <子命令>` 并回传原文，因此
   **原版前端一行不改**就能用：版本、Soter 开关/证书链、keybox 列表与切换、
   隐藏 BL、自动 target.txt、安全补丁日期、keybox 自动更新、Soter 接管范围、targets、日志、debug。
3. **安装/卸载**：安装时**只补缺失的**默认配置（不覆盖已有 `keybox.xml` / `target.txt`），
   卸载时只停本模块目录下的进程，用户配置保留。
4. **核心改造（最小侵入）**：
   - `service.sh`：`/data/adb/modules` 相关探测加 `[ -d ]` 判断（SKRoot 没有这个目录），
     状态文件里多写一行 `manager=skroot`；`DIAG_MODULE_DIR` 默认指向模块目录本身。
   - `core/webui.sh`：`info` 里 `mode/backend` 写 `skroot`，版本兜底改成 `6.0.32_MapleSU`。
   - 补一个 `module.prop`，让 `webui.sh` 能报出真实版本号（SKRoot 侧它只是个数据文件）。

## 目录结构

```
module_teesimulator_maple/
├── module_teesimulator_maple.cpp   # 模块主体：入口 / 启动 / WebUI 桥 / 安装回调
├── tee_utils.h                     # 小工具（文件、带超时 exec、JSON）
├── jni/{Android.mk,Application.mk,build_macros.mk}
├── resources/                      # 安装时释放到模块私有目录
│   ├── service.sh supervisor daemon inject classes.dex
│   ├── libTEESimulator.so libcertgen.so resetprop
│   ├── hide_bootloader.sh sepolicy.rule keybox.xml target.txt module.prop
│   └── core/webui.sh
├── webroot/  wwwroot/              # MapleSU 原版 WebUI（两个目录名都带，兼容文档根差异）
├── pack.sh                         # 一键打包成模块 ZIP
└── .github/workflows/build.yml     # 可选：GitHub Actions 云编译
```

## 编译（.so 必须编，手机上编不了）

需要 **Android NDK r26d 及以上**，只需要 arm64-v8a。

### 方式 A：GitHub Actions（推荐，本仓库已带 workflow）
推送到 GitHub 后 Actions 里手动跑一次 `Build SKRoot TEESimulator-RS MapleSU module`，
产物 `module_TEESimulator_MapleSU_SKRoot`（artifact）就是可安装的 zip。

### 方式 B：本机
```bash
git clone --depth 1 https://github.com/abcz316/SKRoot-linuxKernelRoot.git skroot
cp -r module_teesimulator_maple "skroot/Pro(众测开放中)/src/testModule/"
cd "skroot/Pro(众测开放中)/src/testModule/module_teesimulator_maple/jni"
<NDK>/ndk-build -j4          # 产物：../libs/arm64-v8a/libmodule_teesimulator_maple.so
cd ..
./pack.sh                    # 产物：module_TEESimulator_MapleSU_SKRoot.zip
```

## 安装

1. SKRoot Pro → 模块 → 安装 → 选 `module_TEESimulator_MapleSU_SKRoot.zip`；
2. 重启手机（`skroot_module_main` 在开机早期加载，必须重启才生效）；
3. 打开模块的 WebUI 检查：版本号、Soter 开关、keybox 列表、`/logs` 是否正常。

## 已知限制 / 注意

- **SELinux**：KSU 的 `sepolicy.rule` 由管理器注入，SKRoot 不做这件事。若注入 keystore2 失败
  （WebUI `/logs` 里看到 inject 失败），先用 SKRoot 的 su 手动确认 `keystore2` 是否可 ptrace；
  `sepolicy.rule` 仍随包提供，供你用自己的方式加载。
- **resetprop**：隐藏 BL 依赖包里自带的 `resetprop`（已随包提供）。SKRoot 本身隐藏 root 的方式
  和 Magisk 不同，改属性属于"锦上添花"，失败只会让 `ro.boot.*` 保持原值。
- **配置目录冲突**：和官方 SKRoot port 不同，本包**不会删除** `/data/adb/tricky_store`；
  若你之前装过官方 `module_TEESimulatorRS`，同一个配置目录会被两边共用，建议只留一个。
- **先不要和其它 TEE 模块共存**：两个 daemon 同时注入 keystore2 会让 keystore 卡死
  （`service.sh` 里对 `/data/adb/modules` 的冲突检测在 SKRoot 下不生效）。

# module_teesimulator_maple（工程内说明）

`resources/` 就是 MapleSU 6.0.32 原核心（除脚本里几处 SKRoot 兼容补丁外未改动）。
`.so` 只负责：开机等 boot_completed → 跑 `service.sh`；WebUI 端点 → `sh core/webui.sh <cmd>`。

端点映射见 `module_teesimulator_maple.cpp` 里的 `kRoutes` / `handle_route()`：

| 端点 | webui.sh 命令 |
|---|---|
| /getVersionInfo, /getVersion | `info`（后者取 `version` 字段） |
| /getSoterToggle, /setSoterToggle | `get soter` / `set soter <0|1>` |
| /getSoterCerts, /setSoterCerts | `get soter_certs` / `set soter_certs <0|1|on|off>` |
| /listKeyboxes, /setKeybox | `keyboxes` / `keybox_set <id>` |
| /getHideBootloaderToggle, /setHideBootloaderToggle | `get/set hide_bootloader <0|1>` |
| /getAutoThirdAppToggle, /setAutoThirdAppToggle | `get/set auto_third_app <0|1>` |
| /getFixTeeToggle, /setFixTeeToggle | `get/set fix_tee <0|1>` |
| /getKeyTakeover, /setKeyTakeover | `get/set key_takeover <0|1>` |
| /getSecurityPatch, /setSecurityPatch | `get patch` / `set patch <date|auto|prop>` |
| /keyboxUpdateStatus, /keyboxUpdateConfig, /keyboxUpdateNow | `kbu_status` / `kbu_config <json>` / `kbu_now` |
| /soterScope, /soterScopeSet | `scope list` / `scope set <uids>` 或 `scope setall` |
| /getTargetTxt | `targets` |
| GET /debug, POST /debug | `get debug` / `set debug <0|1>` |
| /logs | `logs` |

额外的自用端点：`/skrootBootLog`（开机日志尾巴）、`/skrootModuleInfo`（自检信息）。

调试小抄（SKRoot su 里执行）：
```sh
sh /data/adb/modules/.../core/webui.sh info      # 模块目录按实际路径替换
sh .../core/webui.sh logs
cat /data/adb/tricky_store/skroot_boot.log
```

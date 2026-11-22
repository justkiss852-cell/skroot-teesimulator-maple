// module_teesimulator_maple.cpp
// ---------------------------------------------------------------------------
// SKRoot(Pro) 模块：把 TEESimulator-RS_MapleSU（原本是 KernelSU 脚本模块）跑在
// SKRoot 环境里。
//
// 本模块只做三件事，核心逻辑全部保留 MapleSU 原版脚本：
//   1. skroot_module_main：SKRoot 在 zygote64 之前加载本 .so，入口只做自检 +
//      fork 一个后台子进程；子进程等 sys.boot_completed=1 后执行原版的
//      service.sh（拉起 supervisor/daemon 注入 keystore2，并做开机 extras）；
//   2. WebUI：MapleSU 原版前端（webroot/）——Ultra 形态下它用 POST fetch 访问
//      一组端点。这里把这些端点一一映射成 `sh core/webui.sh <cmd>`，因此
//      keybox 切换、Soter 开关/范围、补丁日期、证书自动更新、日志等功能
//      全都可以用，不需要改动原版前端；
//   3. 安装/卸载回调：安装时只补默认配置（不覆盖已有 keybox/target；
//      不像官方 port 那样删 /data/adb/tricky_store），卸载时只停本模块的进程。
// ---------------------------------------------------------------------------

#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <ctime>
#include <string>
#include <vector>
#include <unistd.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>

#include "kernel_module_kit_umbrella.h"
#include "tee_utils.h"

#define MOD_VER        "6.0.32-skroot1"
#define CORE_VER       "6.0.32_MapleSU"
#define TEESIM_ID32    "teesimulatormapleskrootpro000001"

// 脚本后端（core/webui.sh）与 .so 两侧共用这些小工具
using namespace tsu;

namespace {

using namespace tsu;

constexpr const char* kConfigDir   = "/data/adb/tricky_store";
constexpr const char* kBootLog     = "/data/adb/tricky_store/skroot_boot.log";
constexpr const char* kModuleLog   = "/data/adb/tricky_store/skroot_module.log";
constexpr const char* kServiceSh   = "service.sh";
constexpr const char* kWebuiSh     = "core/webui.sh";

// 核心必须随 ZIP 一起打包的文件（缺任何一个都记录，但仍然尝试启动）
const char* kCoreFiles[] = {
    "service.sh", "supervisor", "daemon", "classes.dex", "inject",
    "libTEESimulator.so", "core/webui.sh",
};

static std::string g_mod_dir;      // 带结尾 '/'
static std::string g_mod_dir_raw;  // 不带结尾 '/'

// ------------------------------------------------------------------ 日志
static void tee_log(const char* fmt, ...) {
    char msg[2048];
    va_list ap;
    va_start(ap, fmt);
    ::vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);

    ::printf("[teesim_maple] %s\n", msg);
    ::fflush(stdout);

    const std::string target = kModuleLog;
    ensure_dir(kConfigDir);
    FILE* fp = ::fopen(target.c_str(), "a");
    if (!fp) return;
    char ts[32];
    time_t now = ::time(nullptr);
    struct tm tmv {};
    ::localtime_r(&now, &tmv);
    ::strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tmv);
    ::fprintf(fp, "[%s] [pid %d] %s\n", ts, (int)::getpid(), msg);
    ::fclose(fp);
}

static void init_paths(const char* module_private_dir) {
    g_mod_dir = normalize_dir(module_private_dir);
    g_mod_dir_raw = strip_slash(g_mod_dir);
}

static std::string path_of(const std::string& rel) { return g_mod_dir + rel; }

// ------------------------------------------------------------------ 小工具
static std::string getprop(const char* name) {
    char cmd[128];
    ::snprintf(cmd, sizeof(cmd), "getprop %s 2>/dev/null", name);
    return trim(run_cmd_capture(cmd));
}

static bool has_core_files(std::string* missing) {
    bool ok = true;
    for (const char* f : kCoreFiles) {
        if (!file_exists(path_of(f))) {
            ok = false;
            if (missing) { if (!missing->empty()) *missing += ","; *missing += f; }
        }
    }
    return ok;
}

static void chmod_payload() {
    const char* execs[] = {
        "service.sh", "supervisor", "daemon", "inject", "resetprop",
        "hide_bootloader.sh", "core/webui.sh", "uninstall.sh",
    };
    for (const char* f : execs) {
        const std::string p = path_of(f);
        if (file_exists(p)) ::chmod(p.c_str(), 0755);
    }
}

// 当前是否有本模块的 supervisor 在跑（cmdline 里带本模块目录）
static int supervisor_pid() {
    // pidof 快路径：可能有多个 pid
    const std::string pids = run_cmd_capture("pidof supervisor 2>/dev/null");
    std::string cur;
    for (size_t i = 0; i <= pids.size(); ++i) {
        char c = (i < pids.size()) ? pids[i] : (char)32;
        if (c >= (char)48 && c <= (char)57) { cur.push_back(c); continue; }
        if (!cur.empty()) {
            const int pid = ::atoi(cur.c_str());
            cur.clear();
            if (pid > 1 && pid_matches(pid, g_mod_dir_raw)) return pid;
        }
    }
    // ps 兜底：没有 pidof 的 ROM
    const std::string ps = run_cmd_capture("ps -A -o PID,ARGS 2>/dev/null");
    size_t pos = 0;
    while (pos < ps.size()) {
        const size_t nl = ps.find((char)10, pos);
        const std::string line = ps.substr(pos, nl == std::string::npos ? std::string::npos : nl - pos);
        if (line.find("supervisor") != std::string::npos
            && line.find(g_mod_dir_raw) != std::string::npos) {
            const int pid = ::atoi(line.c_str());
            if (pid > 1 && pid_matches(pid, g_mod_dir_raw)) return pid;
        }
        if (nl == std::string::npos) break;
        pos = nl + 1;
    }
    return -1;
}

// ------------------------------------------------------------------ webui.sh 桥
// SKRoot 的 WebUI 由 .so 内的 CivetWeb 提供；MapleSU 原版 WebUI 是
// `sh core/webui.sh <cmd>` 的纯脚本后端。这里把 HTTP 端点映射成命令。
static std::string run_webui(const std::vector<std::string>& args, unsigned timeout_ms) {
    const std::string webui = path_of(kWebuiSh);
    if (!file_exists(webui)) return std::string("{\"ok\":false,\"error\":\"no_webui\"}");

    std::vector<std::string> argv;
    argv.push_back("/system/bin/sh");
    argv.push_back(webui);
    for (const auto& a : args) argv.push_back(a);

    std::string err;
    std::string out = run_argv_capture(argv, timeout_ms, g_mod_dir_raw, &err);
    if (out.empty() && err == "timeout") return std::string("{\"ok\":false,\"error\":\"timeout\"}");
    return trim(out);
}

// 参数表：path + webui.sh 子命令（空格分隔；%BODY% 用请求体替换）
struct RouteDef {
    const char* path;
    const char* cmd;
    unsigned timeout_ms;
};

static const RouteDef kRoutes[] = {
    // 版本 / 信息
    {"/getVersionInfo",           "info",                        15000},
    {"/getVersion",               "info",                        15000},
    // SOTER
    {"/getSoterToggle",           "get soter",                   15000},
    {"/setSoterToggle",           "set soter %BODY%",            15000},
    {"/getSoterCerts",            "get soter_certs",             15000},
    {"/setSoterCerts",            "set soter_certs %BODY%",      15000},
    // KeyBox
    {"/listKeyboxes",             "keyboxes",                    15000},
    {"/setKeybox",                "keybox_set %BODY%",           15000},
    // 系统伪装 / 开关
    {"/getHideBootloaderToggle",  "get hide_bootloader",         15000},
    {"/setHideBootloaderToggle",  "set hide_bootloader %BODY%",  15000},
    {"/getAutoThirdAppToggle",    "get auto_third_app",          15000},
    {"/setAutoThirdAppToggle",    "set auto_third_app %BODY%",   15000},
    {"/getFixTeeToggle",          "get fix_tee",                 15000},
    {"/setFixTeeToggle",          "set fix_tee %BODY%",          15000},
    {"/getKeyTakeover",           "get key_takeover",            15000},
    {"/setKeyTakeover",           "set key_takeover %BODY%",     15000},
    // 安全补丁
    {"/getSecurityPatch",         "get patch",                   15000},
    {"/setSecurityPatch",         "set patch %BODY%",            15000},
    // keybox 自动更新
    {"/keyboxUpdateStatus",       "kbu_status",                  15000},
    {"/keyboxUpdateConfig",       "kbu_config %BODY%",           20000},
    {"/keyboxUpdateNow",          "kbu_now",                    120000},
    // Soter 接管范围（设置走特殊分支）
    {"/soterScope",               "scope list",                  40000},
    // 只读信息 / 诊断
    {"/getTargetTxt",             "targets",                     30000},
    {"/logs",                     "logs",                        40000},
};

static std::vector<std::string> split_cmd(const char* cmd) {
    std::vector<std::string> out;
    std::string cur;
    for (const char* p = cmd; ; ++p) {
        if (*p == ' ' || *p == '\0') {
            if (!cur.empty()) { out.push_back(cur); cur.clear(); }
            if (*p == '\0') break;
        } else {
            cur.push_back(*p);
        }
    }
    return out;
}

static std::string handle_route(const std::string& path, const std::string& body) {
    // 先处理需要解析 JSON 的特殊端点
    if (path == "/soterScopeSet") {
        if (json_pick_bool(body, "all", false)) {
            return run_webui({"scope", "setall"}, 40000);
        }
        const std::string uids = json_pick_number_list(body, "uids");
        return run_webui({"scope", "set", uids}, 40000);
    }
    if (path == "/debug") {
        const bool on = json_pick_bool(body, "enabled", body == "1");
        return run_webui({"set", "debug", on ? "1" : "0"}, 15000);
    }
    // 本模块自带的诊断端点
    if (path == "/skrootBootLog") {
        std::string log = tail_text_file(kBootLog, 32 * 1024);
        if (log.empty()) log = tail_text_file(path_of("skroot_boot.log").c_str(), 32 * 1024);
        if (log.empty()) log = "(暂无开机日志)";
        return log;
    }
    if (path == "/skrootModuleInfo") {
        std::string missing;
        const bool ready = has_core_files(&missing);
        std::string out = "{";
        out += "\"moduleVersion\":"  + json_string(MOD_VER) + ",";
        out += "\"coreVersion\":"    + json_string(CORE_VER) + ",";
        out += "\"moduleDir\":"      + json_string(g_mod_dir_raw) + ",";
        out += "\"coreReady\":"      + std::string(ready ? "true" : "false") + ",";
        out += "\"coreMissing\":"    + json_string(missing) + ",";
        out += "\"webui\":"          + std::string(file_exists(path_of(kWebuiSh)) ? "true" : "false") + ",";
        out += "\"supervisorPid\":"  + std::to_string(supervisor_pid());
        out += "}";
        return out;
    }

    for (const auto& r : kRoutes) {
        if (path != r.path) continue;
        std::vector<std::string> args = split_cmd(r.cmd);
        std::string safe_body;
        for (auto& a : args) {
            if (a == "%BODY%") {
                if (!sanitize_arg(body, safe_body)) {
                    return std::string("{\"ok\":false,\"error\":\"bad_body\"}");
                }
                a = safe_body;
            }
        }
        std::string out = run_webui(args, r.timeout_ms);
        if (path == "/getVersion") {
            // 前端要纯文本版本号
            std::string ver = json_pick_string(out, "version");
            if (!ver.empty()) return ver;
        }
        return out;
    }
    return std::string("{\"ok\":false,\"error\":\"unsupported:") + json_escape(path) + "\"}";
}

// ------------------------------------------------------------------ 开机启动
static void boot_worker() {
    ::setsid();

    // SKRoot 在 zygote64 之前加载模块，此时 keystore2 / 属性服务都还没就绪：
    // 等开机完成再跑原版 service.sh（脚本内部会再做一次 boot 等待，重复无害）。
    for (int i = 0; i < 300; ++i) {
        if (getprop("sys.boot_completed") == "1") break;
        ::sleep(1);
    }
    ::sleep(3);

    ensure_dir(kConfigDir);
    int fd = ::open(kBootLog, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) fd = ::open(path_of("skroot_boot.log").c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd >= 0) {
        ::dup2(fd, STDOUT_FILENO);
        ::dup2(fd, STDERR_FILENO);
        if (fd > STDERR_FILENO) ::close(fd);
    }

    const std::string script = path_of(kServiceSh);
    tee_log("exec %s", script.c_str());
    ::execl("/system/bin/sh", "sh", script.c_str(), (char*)nullptr);
    tee_log("exec service.sh failed, errno=%d", errno);
    ::_exit(127);
}

static bool launch_boot_worker() {
    pid_t pid = ::fork();
    if (pid < 0) { tee_log("fork failed, errno=%d", errno); return false; }
    if (pid == 0) boot_worker();
    return true;
}

} // namespace

// ------------------------------------------------------------------ WebUI
class TeeSimulatorWebHandler : public kernel_module::WebUIHttpHandler {
public:
    void onPrepareCreate(const char* root_key, const char* module_private_dir, uint32_t port) override {
        (void)root_key;
        init_paths(module_private_dir);
        tee_log("webui created, port=%u, dir=%s", (unsigned)port, g_mod_dir_raw.c_str());
    }

    bool handleGet(CivetServer* server, struct mg_connection* conn,
                   const std::string& path, const std::string& query) override {
        (void)server;
        (void)query;
        if (path == "/debug") {
            kernel_module::webui::send_text(conn, 200, run_webui({"get", "debug"}, 15000));
            return true;
        }
        return false;   // 其它 GET 交给 CivetWeb 静态文件服务
    }

    bool handlePost(CivetServer* server, struct mg_connection* conn,
                    const std::string& path, const std::string& body) override {
        (void)server;
        std::string resp = handle_route(path, body);
        kernel_module::webui::send_text(conn, 200, resp);
        return true;
    }
};

// ------------------------------------------------------------------ 安装 / 卸载回调
std::string module_on_install(const char* root_key, const char* module_private_dir) {
    (void)root_key;
    init_paths(module_private_dir);
    tee_log("on install, dir=%s", g_mod_dir_raw.c_str());

    const std::string sdk = getprop("ro.build.version.sdk");
    if (!sdk.empty() && ::atoi(sdk.c_str()) > 0 && ::atoi(sdk.c_str()) < 29) {
        return std::string("TEESimulator-RS 需要 Android 10 (API 29) 及以上，当前 API: ") + sdk;
    }

    chmod_payload();
    ensure_dir(kConfigDir);

    // 只在缺失时补默认配置：绝不覆盖用户已有的 keybox.xml / target.txt
    auto seed = [](const std::string& src, const std::string& dst) {
        if (file_exists(dst) || !file_exists(src)) return;
        std::string text;
        if (read_text_file(src, text, 1u << 20)) {
            if (write_text_file(dst, text)) ::chmod(dst.c_str(), 0644);
        }
    };
    seed(path_of("keybox.xml"),   std::string(kConfigDir) + "/keybox.xml");
    seed(path_of("target.txt"),   std::string(kConfigDir) + "/target.txt");

    if (!file_exists(std::string(kConfigDir) + "/security_patch.txt")) {
        write_text_file(std::string(kConfigDir) + "/security_patch.txt",
                        "# TEESimulator 默认：跟随设备真实属性。\n"
                        "# 想主动伪装时改成 system=YYYY-MM-DD 这类写法。\n"
                        "system=prop\n");
        ::chmod((std::string(kConfigDir) + "/security_patch.txt").c_str(), 0644);
    }
    if (tail_text_file(std::string(kConfigDir) + "/hbk", 1).empty()) {
        run_cmd_capture("head -c 32 /dev/urandom > " + std::string(kConfigDir) + "/hbk 2>/dev/null; "
                        "chmod 0600 " + std::string(kConfigDir) + "/hbk 2>/dev/null");
    }
    tee_log("install done");
    return std::string();   // 空串 = 允许安装
}

void module_on_uninstall(const char* root_key, const char* module_private_dir) {
    (void)root_key;
    init_paths(module_private_dir);
    tee_log("on uninstall, stop our processes only");

    // 只停本模块目录里的 supervisor / daemon，别动别的模块
    const std::string ps = run_cmd_capture("ps -A -o PID,ARGS 2>/dev/null");
    size_t pos = 0;
    while (pos < ps.size()) {
        size_t nl = ps.find('\n', pos);
        std::string line = ps.substr(pos, nl == std::string::npos ? std::string::npos : nl - pos);
        if (!line.empty() && line.find(g_mod_dir_raw) != std::string::npos
            && (line.find("supervisor") != std::string::npos || line.find("TEESimulator") != std::string::npos)) {
            int pid = ::atoi(line.c_str());
            if (pid > 1 && pid_matches(pid, g_mod_dir_raw)) kill_pid(pid, SIGTERM);
        }
        if (nl == std::string::npos) break;
        pos = nl + 1;
    }
    ::unlink(kBootLog);
    ::unlink(kModuleLog);
    ::sync();
}

// ------------------------------------------------------------------ 模块入口
int skroot_module_main(const char* root_key, const char* module_private_dir) {
    (void)root_key;
    init_paths(module_private_dir);

    // 早期环境里 PATH 可能不完整，子进程（webui.sh / service.sh）都靠它
    ::setenv("PATH", "/system/bin:/system/xbin:/vendor/bin:/sbin", 1);
    ::setenv("HOME", "/data/local/tmp", 1);
    ::setenv("ANDROID_DATA", "/data", 0);

    tee_log("module start, dir=%s, core=%s", g_mod_dir_raw.c_str(), CORE_VER);

    chmod_payload();
    ensure_dir(kConfigDir);

    std::string missing;
    if (!has_core_files(&missing)) {
        // 记录但不阻断：和 KEYS/上游语义一致，缺文件时的真实失败留给日志
        tee_log("core files missing: %s (still trying)", missing.c_str());
    }

    const int sup = supervisor_pid();
    if (sup > 0) {
        tee_log("supervisor already running: %d, skip", sup);
        return 0;
    }

    if (!launch_boot_worker()) return 1;
    tee_log("boot worker forked");
    return 0;
}

// ------------------------------------------------------------------ 模块名片
SKROOT_MODULE_NAME("TEESimulator-RS MapleSU")
SKROOT_MODULE_VERSION(MOD_VER)
SKROOT_MODULE_DESC("硬件密钥认证模拟器（MapleSU 6.0.32 定制核心 + SKRoot 适配）：keybox/证书链、Soter、隐藏 BL、target.txt 自动维护")
SKROOT_MODULE_AUTHOR("JingMatrix / Enginex0 / MapleAutumn · SKRoot port")
SKROOT_MODULE_ID32(TEESIM_ID32)
SKROOT_MODULE_WEB_UI(TeeSimulatorWebHandler)
SKROOT_MODULE_ON_INSTALL(module_on_install)
SKROOT_MODULE_ON_UNINSTALL(module_on_uninstall)

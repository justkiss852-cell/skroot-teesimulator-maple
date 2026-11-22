// tee_utils.h
// 模块内部小工具：文件读写、目录创建、带超时执行子进程、pid 管理、JSON 转义/取值。
// 只依赖 bionic 的 libc/stdio，不依赖 SKRoot SDK，方便单独复用与调试。
#pragma once

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cerrno>
#include <ctime>
#include <string>
#include <vector>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>

namespace tsu {

// 统一目录形式：保证以 '/' 结尾，方便拼接
inline std::string normalize_dir(const char* dir) {
    std::string s = (dir && *dir) ? dir : "";
    if (s.empty()) return s;
    if (s.back() != '/') s.push_back('/');
    return s;
}

// 去掉结尾的 '/'（给需要"目录本身"的命令行使用）
inline std::string strip_slash(std::string s) {
    while (!s.empty() && s.back() == '/') s.pop_back();
    return s;
}

inline bool file_exists(const std::string& path) {
    struct stat st {};
    return ::stat(path.c_str(), &st) == 0;
}

inline bool is_dir(const std::string& path) {
    struct stat st {};
    if (::stat(path.c_str(), &st) != 0) return false;
    return S_ISDIR(st.st_mode);
}

inline bool ensure_dir(const std::string& path) {
    if (path.empty()) return false;
    if (is_dir(path)) return true;
    std::string cur;
    cur.reserve(path.size());
    size_t i = 0;
    if (path[0] == '/') { cur = "/"; i = 1; }
    while (i <= path.size()) {
        if (i == path.size() || path[i] == '/') {
            if (!cur.empty() && cur != "/" && !file_exists(cur)) {
                if (::mkdir(cur.c_str(), 0755) != 0 && errno != EEXIST) return false;
            }
            if (i < path.size()) cur.push_back('/');
        } else {
            cur.push_back(path[i]);
        }
        ++i;
    }
    return is_dir(path);
}

inline bool read_text_file(const std::string& path, std::string& out, size_t max_size = 1u << 20) {
    out.clear();
    FILE* fp = ::fopen(path.c_str(), "rb");
    if (!fp) return false;
    char buf[8192];
    size_t n = 0;
    while ((n = ::fread(buf, 1, sizeof(buf), fp)) > 0) {
        out.append(buf, n);
        if (out.size() >= max_size) break;
    }
    ::fclose(fp);
    return true;
}

inline std::string read_text_file(const std::string& path) {
    std::string text;
    read_text_file(path, text);
    return text;
}

// 只读取文件末尾 max_bytes 字节（看日志用）
inline std::string tail_text_file(const std::string& path, size_t max_bytes = 16 * 1024) {
    FILE* fp = ::fopen(path.c_str(), "rb");
    if (!fp) return std::string();
    ::fseek(fp, 0, SEEK_END);
    long size = ::ftell(fp);
    if (size <= 0) { ::fclose(fp); return std::string(); }
    long start = (static_cast<size_t>(size) > max_bytes) ? (size - static_cast<long>(max_bytes)) : 0;
    ::fseek(fp, start, SEEK_SET);
    std::string out;
    out.resize(static_cast<size_t>(size - start));
    size_t got = ::fread(&out[0], 1, out.size(), fp);
    out.resize(got);
    ::fclose(fp);
    return out;
}

inline bool write_text_file(const std::string& path, const std::string& data) {
    FILE* fp = ::fopen(path.c_str(), "wb");
    if (!fp) return false;
    bool ok = (data.empty()) || (::fwrite(data.data(), 1, data.size(), fp) == data.size());
    ::fflush(fp);
    ::fclose(fp);
    return ok;
}

inline std::string trim(const std::string& s) {
    size_t b = 0, e = s.size();
    while (b < e && (s[b] == ' ' || s[b] == '\t' || s[b] == '\r' || s[b] == '\n')) ++b;
    while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t' || s[e - 1] == '\r' || s[e - 1] == '\n')) --e;
    return s.substr(b, e - b);
}

// 同步执行 shell 命令并捕获 stdout（popen，只能在后台线程/进程里用）
inline std::string run_cmd_capture(const std::string& cmd) {
    std::string out;
    FILE* fp = ::popen(cmd.c_str(), "r");
    if (!fp) return out;
    char buf[4096];
    size_t n = 0;
    while ((n = ::fread(buf, 1, sizeof(buf), fp)) > 0) out.append(buf, n);
    ::pclose(fp);
    return out;
}

// fork+exec 执行 argv（不经 shell，参数里带引号也安全），带超时。
//   cwd      为空时保持当前目录
//   timeout  毫秒；<=0 表示不限
// 返回 stdout 内容；err 非空时写入失败原因（超时 / fork 失败等）。
inline std::string run_argv_capture(const std::vector<std::string>& argv,
                                    unsigned timeout_ms,
                                    const std::string& cwd,
                                    std::string* err) {
    std::string out;
    if (argv.empty()) { if (err) *err = "empty argv"; return out; }

    int fds[2];
    if (::pipe(fds) != 0) { if (err) *err = "pipe failed"; return out; }

    pid_t pid = ::fork();
    if (pid < 0) {
        ::close(fds[0]);
        ::close(fds[1]);
        if (err) *err = "fork failed";
        return out;
    }
    if (pid == 0) {
        ::close(fds[0]);
        ::dup2(fds[1], STDOUT_FILENO);
        int devnull = ::open("/dev/null", O_WRONLY);
        if (devnull >= 0) ::dup2(devnull, STDERR_FILENO);
        ::close(fds[1]);
        if (devnull > STDERR_FILENO) ::close(devnull);
        if (!cwd.empty()) { if (::chdir(cwd.c_str()) != 0) { /* 保持原目录 */ } }
        std::vector<char*> cargv;
        cargv.reserve(argv.size() + 1);
        for (const auto& a : argv) cargv.push_back(const_cast<char*>(a.c_str()));
        cargv.push_back(nullptr);
        ::execv(cargv[0], cargv.data());
        ::_exit(127);
    }

    ::close(fds[1]);
    const bool timed = (timeout_ms > 0);
    struct timespec start {};
    ::clock_gettime(CLOCK_MONOTONIC, &start);

    char buf[4096];
    bool timed_out = false;
    for (;;) {
        int wait_ms = 200;
        if (timed) {
            struct timespec now {};
            ::clock_gettime(CLOCK_MONOTONIC, &now);
            long elapsed = (long)(now.tv_sec - start.tv_sec) * 1000
                         + (long)(now.tv_nsec - start.tv_nsec) / 1000000;
            long left = (long)timeout_ms - elapsed;
            if (left <= 0) { timed_out = true; break; }
            if (left < wait_ms) wait_ms = (int)left;
        }
        struct pollfd pfd {};
        pfd.fd = fds[0];
        pfd.events = POLLIN;
        int pr = ::poll(&pfd, 1, wait_ms);
        if (pr < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (pr == 0) continue;
        ssize_t n = ::read(fds[0], buf, sizeof(buf));
        if (n > 0) {
            out.append(buf, (size_t)n);
            if (out.size() > (8u << 20)) break;
        } else if (n == 0) {
            break;
        } else {
            if (errno == EINTR || errno == EAGAIN) continue;
            break;
        }
    }
    ::close(fds[0]);

    if (timed_out) {
        ::kill(pid, SIGKILL);
        if (err) *err = "timeout";
    }
    int status = 0;
    while (::waitpid(pid, &status, 0) < 0 && errno == EINTR) { }
    return out;
}

inline int read_pid_file(const std::string& path) {
    std::string text = trim(read_text_file(path));
    if (text.empty()) return -1;
    char* end = nullptr;
    long pid = ::strtol(text.c_str(), &end, 10);
    if (pid <= 1) return -1;
    return static_cast<int>(pid);
}

inline bool pid_alive(int pid) {
    if (pid <= 1) return false;
    return ::kill(pid, 0) == 0;
}

// 判断 /proc/<pid>/cmdline 里是否包含 keyword，避免误杀复用了 pid 的其它进程
inline bool pid_matches(int pid, const std::string& keyword) {
    if (!pid_alive(pid)) return false;
    std::string cmdline;
    char path[64];
    ::snprintf(path, sizeof(path), "/proc/%d/cmdline", pid);
    if (!read_text_file(path, cmdline, 4096)) return false;
    for (size_t i = 0; i < cmdline.size(); ++i) {
        if (cmdline[i] == '\0') cmdline[i] = ' ';
    }
    return cmdline.find(keyword) != std::string::npos;
}

inline bool kill_pid(int pid, int sig = SIGTERM) {
    if (pid <= 1) return false;
    return ::kill(pid, sig) == 0;
}

// 简单 JSON 字符串转义
inline std::string json_escape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 16);
    for (char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:
                if (static_cast<unsigned char>(c) < 0x20) {
                    char buf[8];
                    ::snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned char>(c));
                    out += buf;
                } else {
                    out.push_back(c);
                }
        }
    }
    return out;
}

inline std::string json_string(const std::string& s) {
    return "\"" + json_escape(s) + "\"";
}

// 从一段 JSON 文本里取出 "key":"value" 的字符串值（够用即可，不引入 JSON 库）
inline std::string json_pick_string(const std::string& json, const char* key) {
    const std::string pat = std::string("\"") + key + "\"";
    size_t pos = json.find(pat);
    if (pos == std::string::npos) return std::string();
    pos = json.find(':', pos + pat.size());
    if (pos == std::string::npos) return std::string();
    ++pos;
    while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t')) ++pos;
    if (pos >= json.size() || json[pos] != '"') return std::string();
    ++pos;
    std::string out;
    bool esc = false;
    for (; pos < json.size(); ++pos) {
        char c = json[pos];
        if (esc) {
            switch (c) {
                case 'n': out.push_back('\n'); break;
                case 't': out.push_back('\t'); break;
                case 'r': out.push_back('\r'); break;
                default:  out.push_back(c);   break;
            }
            esc = false;
            continue;
        }
        if (c == '\\') { esc = true; continue; }
        if (c == '"') break;
        out.push_back(c);
    }
    return out;
}

// 取 JSON 里的数字数组，例如 {"uids":[10001,10002]} -> "10001,10002"
inline std::string json_pick_number_list(const std::string& json, const char* key) {
    const std::string pat = std::string("\"") + key + "\"";
    size_t pos = json.find(pat);
    if (pos == std::string::npos) return std::string();
    size_t lb = json.find('[', pos);
    if (lb == std::string::npos) return std::string();
    size_t rb = json.find(']', lb);
    if (rb == std::string::npos) return std::string();
    std::string body = json.substr(lb + 1, rb - lb - 1);
    std::string out;
    std::string cur;
    for (size_t i = 0; i <= body.size(); ++i) {
        char c = (i < body.size()) ? body[i] : ',';
        if (c >= '0' && c <= '9') { cur.push_back(c); continue; }
        if (!cur.empty()) {
            if (!out.empty()) out.push_back(',');
            out += cur;
            cur.clear();
        }
    }
    return out;
}

// 取 JSON 里的布尔值（"all":true 这类），找不到返回 fallback
inline bool json_pick_bool(const std::string& json, const char* key, bool fallback) {
    const std::string pat = std::string("\"") + key + "\"";
    size_t pos = json.find(pat);
    if (pos == std::string::npos) return fallback;
    pos = json.find(':', pos + pat.size());
    if (pos == std::string::npos) return fallback;
    ++pos;
    while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t')) ++pos;
    if (json.compare(pos, 4, "true") == 0) return true;
    if (json.compare(pos, 5, "false") == 0) return false;
    if (pos < json.size() && json[pos] == '1') return true;
    if (pos < json.size() && json[pos] == '0') return false;
    return fallback;
}

// 请求体只允许可打印字符，防止把控制字符塞进命令行
inline bool sanitize_arg(const std::string& in, std::string& out, size_t max_len = 4096) {
    if (in.size() > max_len) return false;
    out.clear();
    out.reserve(in.size());
    for (char c : in) {
        unsigned char u = static_cast<unsigned char>(c);
        if (u < 0x20 && u != '\t') return false;
        out.push_back(c);
    }
    return true;
}

} // namespace tsu

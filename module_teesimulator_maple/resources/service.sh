#!/system/bin/sh
# MapleSU packaging of the upstream TEESimulator-RS boot service.
#
# Boot chain (identical in behaviour to upstream v6.0.1 service.sh, which is the
# only configuration verified on a real KernelSU device):
#
#     MODDIR=${0%/*}; cd "$MODDIR"
#     ./supervisor ./daemon "$MODDIR" &
#
# The daemon must run with its working directory at the module root: the dex
# resolves three paths against it (Keystore2Interceptor `exec ./inject `pidof
# keystore2` libTEESimulator.so entry`; App.main
# `new File("libcertgen.so").getAbsolutePath()`; mpl.SoterInjector `core=$(pwd)`).
#
# Deliberately NOT done here (6.0.10 root-cause audit):
#   * no post-fs-data stage - upstream starts the daemon once, at the service
#     stage, when keystore2 and system_server exist;
#   * no kill of a running TEESimulator - components/supervisor is a fork/exec
#     respawn loop (main @0xaa0: fork -> prctl(PDEATHSIG,9) -> execv ->
#     waitpid -> usleep), so killing the daemon only makes the old supervisor
#     fork another one while this script starts a second supervisor: two daemons
#     then inject into keystore2 concurrently and keystore can end up wedged
#     ("no certificate chain at all").
#
# MapleSU additions, none of which can block the core start:
#   * first-install seeding of /data/adb/tricky_store (the dex's canonical
#     config dir): keybox.xml, target.txt, security_patch.txt, hbk, soter_certs.
#     Seeding is create-only: an existing keybox.xml is never overwritten;
#   * /data/adb/tricky_store/ksu_status, the machine-readable boot record the
#     WebUI reads (supervisor, daemon, inject, hide_bootloader, boot_apply, kbu);
#   * hide_bootloader.sh, `webui.sh boot-apply` and the keybox auto-update, all
#     inside ONE detached background subshell *after* the supervisor is up, so a
#     slow `pm`, a missing network or a broken helper can never fail the module;
#   * two diagnostic snapshots (20s / 60s) appended to
#     /sdcard/Download/tee_diag.txt from a nested detached subshell, so a KSU
#     device can be diagnosed without another blind install.
#
# 6.0.11 boot-chain change: the five-file preflight no longer gates the start.
# It records `core=incomplete:<files>` (or `core=nocd`) in ksu_status and the
# supervisor is started unconditionally, which is upstream's semantics - upstream
# has no preflight at all. The old `exit 0` made a single missing or unreadable
# file look exactly like "TEE does not work", with no daemon, no log and no retry.
#
# Test hooks (never set on a device): MAPLESU_TEE_CONFIG_DIR, MAPLESU_TEE_LITE_DIR,
# MAPLESU_TEE_KIT_STATUS, MAPLESU_TEE_DIAG_FILE, MAPLESU_TEE_DIAG_DELAYS,
# MAPLESU_TEE_MODULE_DIR and MAPLESU_TEE_BOOT_WAIT override the absolute paths,
# the snapshot delays and the final boot-completed wait for a local dry run.

case ${0:-} in
    */*) MODDIR=${0%/*} ;;
    *)   MODDIR=$(pwd) ;;
esac
MODDIR=${MODDIR%/}
[ -n "$MODDIR" ] || MODDIR=.

CONFIG_DIR=${MAPLESU_TEE_CONFIG_DIR:-/data/adb/tricky_store}
LITE_DIR=${MAPLESU_TEE_LITE_DIR:-/data/adb/maplesu/tee}
KIT_STATUS=${MAPLESU_TEE_KIT_STATUS:-/data/adb/maplesu/kit/status}
STATUS_FILE="$CONFIG_DIR/ksu_status"
BOOT_LOG="$CONFIG_DIR/ksu_boot.log"

# Diagnostics (6.0.11): two snapshots written to the shared storage so the user
# can `adb pull /sdcard/Download/tee_diag.txt` without root on the host.
DIAG_FILE=${MAPLESU_TEE_DIAG_FILE:-/sdcard/Download/tee_diag.txt}
DIAG_FALLBACK=$CONFIG_DIR/tee_diag.txt
DIAG_LOCK=$CONFIG_DIR/.diag_lock
DIAG_MODULE_DIR=${MAPLESU_TEE_MODULE_DIR:-$MODDIR}
DIAG_DELAYS=${MAPLESU_TEE_DIAG_DELAYS:-20 60}
BOOT_WAIT_MAX=${MAPLESU_TEE_BOOT_WAIT:-180}
_DIAG_DEST=
_DIAG_TMP=

# --- helpers ---------------------------------------------------------------

log_msg() {
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$*" >> "$BOOT_LOG" 2>/dev/null
    return 0
}

set_status() {
    # One `key=value` line per boot; the file is truncated at the start of a run.
    printf '%s=%s\n' "$1" "$2" >> "$STATUS_FILE" 2>/dev/null
    return 0
}

flag_value() {
    # flag_value <file> <default>: 1/0 with the usual text aliases.
    _fv=$(tr -d ' \t\r\n' < "$1" 2>/dev/null | tr 'A-Z' 'a-z')
    case $_fv in
        1|on|true|yes) printf '1' ;;
        0|off|false|no) printf '0' ;;
        *) printf '%s' "$2" ;;
    esac
}

pid_of() {
    # pid_of <name>: first pid or an empty string. pidof is the fast path; ps is a
    # fallback for images without toybox pidof.
    _pid=$(pidof "$1" 2>/dev/null | tr ' ' '\n' | sed -n '1p')
    if [ -z "$_pid" ]; then
        _pid=$(ps -A -o PID,NAME 2>/dev/null \
            | sed -n "s/^[[:space:]]*\([0-9][0-9]*\)[[:space:]][[:space:]]*$1\$/\1/p" \
            | sed -n '1p')
    fi
    printf '%s' "$_pid"
}

supervisor_pid() {
    # Only OUR supervisor: its command line carries this module's directory as
    # the daemon's argv ("<module>/supervisor <module>/daemon <module>").
    for _sp in $(pidof supervisor 2>/dev/null); do
        case $(tr '\0' ' ' < "/proc/$_sp/cmdline" 2>/dev/null) in
            *"$MODDIR"*) printf '%s' "$_sp"; return 0 ;;
        esac
    done
    return 1
}

seed_file() {
    # seed_file <name>: first install only, never overwritten. A file already in
    # the Lite directory wins over the packaged default so an existing user keeps
    # their own keybox/target list when the canonical directory changes.
    _sf=$1
    if [ -f "$CONFIG_DIR/$_sf" ]; then
        return 0
    fi
    if [ -f "$LITE_DIR/$_sf" ]; then
        if cp -f "$LITE_DIR/$_sf" "$CONFIG_DIR/$_sf" 2>/dev/null; then
            chmod 0644 "$CONFIG_DIR/$_sf" 2>/dev/null
            log_msg "seeded $_sf from $LITE_DIR"
            return 0
        fi
    fi
    if [ -f "$MODDIR/$_sf" ]; then
        if cp -f "$MODDIR/$_sf" "$CONFIG_DIR/$_sf" 2>/dev/null; then
            chmod 0644 "$CONFIG_DIR/$_sf" 2>/dev/null
            log_msg "seeded $_sf from module"
            return 0
        fi
    fi
    return 1
}

mirror_to_lite() {
    # Keep /data/adb/maplesu/tee readable for the Lite backend by pointing it at
    # the canonical file. A symlink is used so the two paths cannot drift; a
    # filesystem without symlinks falls back to a copy.
    [ -d "$LITE_DIR" ] || return 1
    _mf=$1
    [ -f "$CONFIG_DIR/$_mf" ] || return 1
    if [ -L "$LITE_DIR/$_mf" ]; then
        if [ "$(readlink "$LITE_DIR/$_mf" 2>/dev/null)" = "$CONFIG_DIR/$_mf" ]; then
            return 0
        fi
        rm -f "$LITE_DIR/$_mf" 2>/dev/null
    elif [ -f "$LITE_DIR/$_mf" ]; then
        if cmp -s "$CONFIG_DIR/$_mf" "$LITE_DIR/$_mf" 2>/dev/null; then
            return 0
        fi
        rm -f "$LITE_DIR/$_mf" 2>/dev/null
    fi
    if ln -s "$CONFIG_DIR/$_mf" "$LITE_DIR/$_mf" 2>/dev/null; then
        return 0
    fi
    cp -f "$CONFIG_DIR/$_mf" "$LITE_DIR/$_mf" 2>/dev/null \
        && chmod 0644 "$LITE_DIR/$_mf" 2>/dev/null
}

inject_state() {
    # The daemon runs `exec ./inject `pidof keystore2` libTEESimulator.so entry`,
    # so the library showing up in keystore2's maps is the ground truth for "the
    # injection actually happened". Unreadable /proc or a missing keystore2 is
    # unknown, never a fabricated failure.
    _ks=$(pid_of keystore2)
    if [ -z "$_ks" ]; then
        printf 'unknown'
        return 0
    fi
    if [ ! -r "/proc/$_ks/maps" ]; then
        printf 'unknown'
        return 0
    fi
    if grep -q 'libTEESimulator\.so' "/proc/$_ks/maps" 2>/dev/null; then
        printf 'ok'
    else
        printf 'fail'
    fi
    return 0
}

# --- diagnostics (6.0.11) ---------------------------------------------------
#
# A KSU install that "does nothing" can only be diagnosed from device state, and
# the user is not going to keep flashing packages. Every probe below is guarded:
# a missing tool, a denied /proc or a failed command writes one `[fail: ...]`
# line and the snapshot continues. Nothing here can change the boot outcome.

diag_now() {
    date '+%Y-%m-%d %H:%M:%S' 2>/dev/null
}

diag_open() {
    # Pick the first writable dump path; nonzero when none is usable.
    [ -n "$_DIAG_DEST" ] && return 0
    for _cand in "$DIAG_FILE" "$DIAG_FALLBACK"; do
        _cdir=${_cand%/*}
        [ -d "$_cdir" ] || continue
        if : >> "$_cand" 2>/dev/null; then
            _DIAG_DEST=$_cand
            return 0
        fi
    done
    return 1
}

diag_pid_alive() {
    case $1 in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -gt 0 ] 2>/dev/null || return 1
    kill -0 "$1" 2>/dev/null
}

diag_lock_free() {
    # No lock, or a stale one: its writer is gone (reboot, crash, kill -9), so
    # the next boot may take it over instead of losing the diagnostics forever.
    [ -f "$DIAG_LOCK" ] || return 0
    _lp=$(cat "$DIAG_LOCK" 2>/dev/null)
    if diag_pid_alive "$_lp"; then
        return 1
    fi
    rm -f "$DIAG_LOCK" 2>/dev/null
    return 0
}

diag_unlock() {
    rm -f "$DIAG_LOCK" 2>/dev/null
    return 0
}

diag_start() {
    # Single-instance writer, forked from the extras subshell: check the lock,
    # fork, then record the *child* pid. $$ is the service.sh pid in every
    # subshell (POSIX) and service.sh exits right after the extras start, so the
    # lock must name the snapshot subshell itself - $! is the only pid a POSIX
    # shell can know here. The child is the only writer and drops the lock when
    # it is done.
    if ! diag_open; then
        log_msg "diag: neither $DIAG_FILE nor $DIAG_FALLBACK is writable"
        return 0
    fi
    if ! diag_lock_free; then
        log_msg "diag: $DIAG_LOCK is held by a live writer; skipping this boot"
        return 0
    fi
    ( diag_loop ) >> "$BOOT_LOG" 2>&1 &
    printf '%s\n' "$!" > "$DIAG_LOCK" 2>/dev/null
    return 0
}

diag_tmp() {
    if [ -z "$_DIAG_TMP" ]; then
        _DIAG_TMP="$CONFIG_DIR/.diag.$$"
    fi
    printf '%s' "$_DIAG_TMP"
}

diag_field() {
    # diag_field <label> <cmd...> -> "label: value", or "[fail: label ...]".
    _df_label=$1
    shift
    _df_out=$("$@" 2>/dev/null)
    _df_rc=$?
    printf '%s: ' "$_df_label"
    if [ "$_df_rc" -ne 0 ]; then
        printf '[fail: %s rc=%s]\n' "$_df_label" "$_df_rc"
    elif [ -z "$_df_out" ]; then
        printf '[fail: %s empty]\n' "$_df_label"
    else
        printf '%s\n' "$_df_out"
    fi
    return 0
}

diag_ps() {
    _dp=$(diag_tmp).ps
    if ps -A -o PID,PPID,USER,NAME > "$_dp" 2>&1; then
        grep -E 'supervisor|TEESimulator|keystore2|soterserver' "$_dp" 2>/dev/null \
            || printf '(no matching process)\n'
    else
        printf '[fail: ps -A]\n'
        head -3 "$_dp" 2>/dev/null
    fi
    rm -f "$_dp" 2>/dev/null
    return 0
}

diag_cwd() {
    _dc=$(pid_of TEESimulator)
    if [ -z "$_dc" ]; then
        printf '[fail: no TEESimulator pid]\n'
        return 0
    fi
    _dw=$(readlink "/proc/$_dc/cwd" 2>/dev/null)
    if [ $? -eq 0 ] && [ -n "$_dw" ]; then
        printf '%s\n' "$_dw"
    else
        printf '[fail: readlink /proc/%s/cwd]\n' "$_dc"
    fi
    return 0
}

diag_maps() {
    _dm=$(pid_of keystore2)
    if [ -z "$_dm" ]; then
        printf '[fail: no keystore2 pid]\n'
        return 0
    fi
    if [ ! -r "/proc/$_dm/maps" ]; then
        printf '[fail: /proc/%s/maps unreadable]\n' "$_dm"
        return 0
    fi
    # grep -c prints 0 and exits 1 when the pattern is absent (a real "0"), but
    # prints nothing and exits 2 when /proc/<pid>/maps cannot be read. Counting a
    # denied read as "0" would turn a permissions problem into "not injected".
    _dn=$(grep -c 'libTEESimulator' "/proc/$_dm/maps" 2>/dev/null)
    _drc=$?
    case $_dn in
        ''|*[!0-9]*) _dn= ;;
    esac
    if [ -z "$_dn" ]; then
        printf '[fail: grep /proc/%s/maps rc=%s]\n' "$_dm" "$_drc"
    else
        printf '%s\n' "$_dn"
    fi
    return 0
}

diag_logcat() {
    _dl=$(diag_tmp).logcat
    if logcat -d -s TEESimulator MPL-BUILD MPL-SOTER AndroidRuntime > "$_dl" 2>&1; then
        if [ -s "$_dl" ]; then
            tail -150 "$_dl" 2>/dev/null
        else
            printf '(no matching log lines)\n'
        fi
    else
        printf '[fail: logcat]\n'
        head -3 "$_dl" 2>/dev/null
    fi
    rm -f "$_dl" 2>/dev/null
    return 0
}

diag_avc() {
    _da=$(diag_tmp).dmesg
    if dmesg > "$_da" 2>&1; then
        _dv=$(grep -i 'avc' "$_da" 2>/dev/null | tail -30)
        if [ -n "$_dv" ]; then
            printf '%s\n' "$_dv"
        else
            printf '(no avc lines)\n'
        fi
    else
        printf 'dmesg: denied\n'
    fi
    rm -f "$_da" 2>/dev/null
    return 0
}

diag_ls() {
    _do=$(diag_tmp).ls
    if ls -l "$DIAG_MODULE_DIR" > "$_do" 2>&1; then
        cat "$_do" 2>/dev/null
    else
        printf '[fail: ls %s]\n' "$DIAG_MODULE_DIR"
        head -3 "$_do" 2>/dev/null
    fi
    rm -f "$_do" 2>/dev/null
    return 0
}

diag_snapshot() {
    _dw=$1
    diag_open || return 1
    {
        printf '\n============================================================\n'
        printf 'TEESimulator-RS_MapleSU KSU diagnostic snapshot: %s\n' "$_dw"
        printf 'local time: %s\n' "$(diag_now)"
        printf 'utc time  : %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
        printf 'module dir: %s\n' "$MODDIR"
        printf 'config dir: %s\n' "$CONFIG_DIR"
        printf 'dump file : %s\n' "$_DIAG_DEST"
        printf '============================================================\n'

        printf '\n[1] build\n'
        printf 'date: %s\n' "$(diag_now)"
        diag_field 'ro.build.version.release' getprop ro.build.version.release
        diag_field 'ro.product.model' getprop ro.product.model
        diag_field 'uname -r' uname -r

        printf '\n[2] %s/ksu_status\n' "$CONFIG_DIR"
        if [ -f "$CONFIG_DIR/ksu_status" ]; then
            cat "$CONFIG_DIR/ksu_status" 2>/dev/null || printf '[fail: cat ksu_status]\n'
        else
            printf 'missing\n'
        fi

        printf '\n[3] PID PPID USER NAME (supervisor|TEESimulator|keystore2|soterserver)\n'
        diag_ps

        printf '\n[4] daemon cwd (must be the module dir)\n'
        diag_cwd

        printf '\n[5] keystore2 maps: libTEESimulator count (>0 = injected)\n'
        diag_maps

        printf '\n[6] logcat -d -s TEESimulator MPL-BUILD MPL-SOTER AndroidRuntime (tail 150)\n'
        diag_logcat

        printf '\n[7] dmesg avc (tail 30)\n'
        diag_avc

        printf '\n[8] ls -l %s\n' "$DIAG_MODULE_DIR"
        diag_ls

        printf '\n[9] %s/target.txt (head 40)\n' "$CONFIG_DIR"
        if [ -f "$CONFIG_DIR/target.txt" ]; then
            head -40 "$CONFIG_DIR/target.txt" 2>/dev/null \
                || printf '[fail: head target.txt]\n'
        else
            printf '[fail: target.txt missing]\n'
        fi

        printf '\n[10] keybox DeviceID(s) + utc\n'
        if [ -f "$CONFIG_DIR/keybox.xml" ]; then
            _dv=$(grep -o 'DeviceID="[^"]*"' "$CONFIG_DIR/keybox.xml" 2>/dev/null | head -2)
            if [ -n "$_dv" ]; then
                printf '%s\n' "$_dv"
            else
                printf '[fail: no DeviceID in keybox.xml]\n'
            fi
        else
            printf '[fail: keybox.xml missing]\n'
        fi
        printf 'date -u: %s\n' "$(date -u 2>/dev/null)"
    } >> "$_DIAG_DEST" 2>/dev/null
    chmod 0644 "$_DIAG_DEST" 2>/dev/null
    log_msg "diag snapshot written: $_dw -> $_DIAG_DEST"
    return 0
}

diag_loop() {
    # The forked writer started by diag_start(): one snapshot at 20s and one at
    # 60s after the service stage. The lock already names this pid.
    if ! diag_open; then
        log_msg "diag: no writable dump path in the writer; nothing recorded"
        diag_unlock
        return 0
    fi
    _snaps=0
    _prev=0
    for _d in $DIAG_DELAYS; do
        case $_d in
            ''|*[!0-9]*) continue ;;
        esac
        _step=$((_d - _prev))
        [ "$_step" -gt 0 ] 2>/dev/null || _step=0
        if [ "$_step" -gt 0 ]; then
            sleep "$_step"
        fi
        _prev=$_d
        _snaps=$((_snaps + 1))
        diag_snapshot "after ${_d}s (#${_snaps})"
    done
    chmod 0644 "$_DIAG_DEST" 2>/dev/null
    diag_unlock
    log_msg "diag: $_snaps snapshot(s) appended to $_DIAG_DEST"
    return 0
}

# --- 0. status scaffold ----------------------------------------------------

mkdir -p "$CONFIG_DIR" 2>/dev/null
if [ ! -d "$CONFIG_DIR" ]; then
    echo "TEESimulator: cannot create $CONFIG_DIR; nothing to do" >&2
    exit 0
fi

if [ -f "$BOOT_LOG" ]; then
    _sz=$(wc -c < "$BOOT_LOG" 2>/dev/null | tr -d ' ')
    case $_sz in
        ''|*[!0-9]*) _sz=0 ;;
    esac
    if [ "$_sz" -gt 65536 ] 2>/dev/null; then
        : > "$BOOT_LOG" 2>/dev/null
    fi
fi

: > "$STATUS_FILE" 2>/dev/null
set_status time "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
set_status module "$MODDIR"
set_status manager skroot
set_status config "$CONFIG_DIR"
log_msg "=== TEESimulator service.sh start (6.0.11) ==="
log_msg "MODDIR=$MODDIR"

# --- 1. canonical config files (first install only) ------------------------

seed_file keybox.xml || true
seed_file target.txt || true
seed_file security_patch.txt || true
seed_file hbk || true

# 6.0.13: certificate chain defaults to OFF (absent file = off); only an
# explicit "on" from the WebUI enables it. Soter compatibility stays on.
if [ -f "$CONFIG_DIR/soter_certs" ]; then
    set_status soter_certs "$( [ "$(cat "$CONFIG_DIR/soter_certs" 2>/dev/null)" = on ] && echo on || echo off )"
else
    set_status soter_certs off
fi

if [ ! -f "$CONFIG_DIR/security_patch.txt" ]; then
    printf '%s\n' \
        '# TEESimulator default: mirror live device props.' \
        '# system=prop reads ro.build.version.security_patch at cert-gen time;' \
        '# boot and vendor are auto-forced to prop too.' \
        '# Override with explicit YYYY-MM-DD dates if you want active spoofing.' \
        'system=prop' > "$CONFIG_DIR/security_patch.txt" 2>/dev/null
    chmod 0644 "$CONFIG_DIR/security_patch.txt" 2>/dev/null
fi

if [ ! -s "$CONFIG_DIR/hbk" ]; then
    head -c 32 /dev/urandom > "$CONFIG_DIR/hbk" 2>/dev/null \
        || head -c 32 /dev/random > "$CONFIG_DIR/hbk" 2>/dev/null
    chmod 0600 "$CONFIG_DIR/hbk" 2>/dev/null
fi

if [ -s "$CONFIG_DIR/keybox.xml" ]; then
    set_status keybox ok
else
    set_status keybox missing
    log_msg "keybox.xml is missing or empty in $CONFIG_DIR: the dex has no key material"
fi

if [ -f "$CONFIG_DIR/target.txt" ]; then
    set_status target ok
else
    set_status target missing
fi

if [ -s "$CONFIG_DIR/security_patch.txt" ]; then
    set_status security_patch ok
else
    set_status security_patch missing
fi

if [ -s "$CONFIG_DIR/hbk" ]; then
    set_status hbk ok
else
    set_status hbk missing
fi

# kernel-side kit (Ultra only): recorded, never fatal on KSU.
if [ -f "$KIT_STATUS" ] && grep -q '^tee_kit=unavailable' "$KIT_STATUS" 2>/dev/null; then
    _reason=$(sed -n 's/^tee_kit_reason=//p' "$KIT_STATUS" 2>/dev/null | sed -n '1p')
    set_status kit unavailable
    set_status kit_reason "${_reason:-unknown}"
else
    set_status kit absent
fi

# --- 2. core: upstream boot chain, started exactly once ---------------------
#
# 6.0.11: the preflight is a *record*, not a gate. Upstream starts the supervisor
# unconditionally and lets the daemon log its own failure; the old `exit 0` here
# turned one missing/unreadable file into a silent no-op that looked identical to
# "TEE does not work" (no daemon, no log line, no retry). The missing files are
# recorded as core=incomplete:<list> in ksu_status and the start below still runs.

_CORE_MISSING=
for _cf in supervisor daemon classes.dex inject libTEESimulator.so; do
    [ -f "$MODDIR/$_cf" ] || _CORE_MISSING="$_CORE_MISSING $_cf"
done
_CORE_STATE=ok
if [ -n "$_CORE_MISSING" ]; then
    _CORE_STATE="incomplete:${_CORE_MISSING# }"
    log_msg "core files missing:${_CORE_MISSING} (starting anyway, upstream semantics)"
fi
if ! cd "$MODDIR" 2>/dev/null; then
    # Recorded, not fatal: the start below is still attempted, like upstream.
    _CORE_STATE=nocd
    log_msg "cannot cd to $MODDIR (starting anyway)"
fi
set_status core "$_CORE_STATE"

# --- 2b. install integrity + duplicate-instance guard (6.0.16) --------------
#
# Two failures look identical ("KSU is fine, the module does nothing"):
#   1. /data/adb/modules/<id> is a symlink into a manager's private storage
#      (MapleSU installs like that). If the manager clears that storage the link
#      dangles, module.prop disappears and KSU silently treats the module as
#      absent. We cannot even run in that state; recording it makes it visible.
#   2. Another TEESimulator/TrickyStore module is enabled. Both daemons inject
#      into keystore2, the hooks fight and keystore requests block/fail. Start
#      only one: record the conflict and skip our daemon start.
_SELF_ID=$(basename "$MODDIR" 2>/dev/null)
if [ -d /data/adb/modules ]; then
    # KernelSU / Magisk 形态：模块目录在 /data/adb/modules/<id>
    if [ -n "$_SELF_ID" ] && [ -L "/data/adb/modules/$_SELF_ID" ]; then
        set_status install "symlink:$(readlink "/data/adb/modules/$_SELF_ID" 2>/dev/null)"
    else
        set_status install realdir
    fi
else
    # SKRoot(Pro) 形态：没有 /data/adb/modules，模块由 SKRoot 加载 .so 驱动
    set_status install skroot
fi

_CONFLICTS=
for _m in /data/adb/modules/*; do
    [ -d "$_m" ] || continue
    _mid=$(basename "$_m")
    [ "$_mid" = "$_SELF_ID" ] && continue
    [ -f "$_m/disable" ] && continue
    [ -f "$_m/module.prop" ] || continue
    _mname=$(sed -n 's/^name=//p' "$_m/module.prop" 2>/dev/null | sed -n '1p')
    _mdesc=$(sed -n 's/^description=//p' "$_m/module.prop" 2>/dev/null | sed -n '1p')
    case "$_mid $_mname" in
        *tricky_store*|*TEESimulator*|*TrickyStore*) _CONFLICTS="$_CONFLICTS $_mid" ;;
        *) case "$_mdesc" in *TEESimulator*|*TrickyStore*) _CONFLICTS="$_CONFLICTS $_mid" ;; esac ;;
    esac
done
# Upgrading from our previous module id (teesimulator-rs -> tricky_store) would
# otherwise leave two copies: the old dir keeps its own daemon alive. Neutralise
# the legacy copy and stop its daemon before the conflict check.
for _legacy_id in teesimulator-rs trick_store; do
    case " $_CONFLICTS " in
        *" $_legacy_id "*)
            _legacy=/data/adb/modules/$_legacy_id
            if [ -f "$_legacy/module.prop" ] \
                && grep -q '^name=TEESimulator-RS' "$_legacy/module.prop" 2>/dev/null; then
                : > "$_legacy/disable" 2>/dev/null
                for _p in $(pidof TEESimulator 2>/dev/null); do kill "$_p" 2>/dev/null; done
                log_msg "migrated legacy module id: disabled /data/adb/modules/$_legacy_id"
                _CONFLICTS=$(printf ' %s ' "$_CONFLICTS" | sed "s/ $_legacy_id / /")
            fi
            ;;
    esac
done

if [ -n "$_CONFLICTS" ]; then
    set_status conflict "${_CONFLICTS# }"
    log_msg "another TEE module is enabled:${_CONFLICTS}; not starting a second daemon"
    set_status done 0
    exit 0
fi

_SUP=$(supervisor_pid)
if [ -n "$_SUP" ]; then
    set_status supervisor "running:$_SUP"
    log_msg "supervisor already running: $_SUP"
else
    # Upstream: ./supervisor ./daemon "$MODDIR" &
    ./supervisor ./daemon "$MODDIR" >> "$BOOT_LOG" 2>&1 &
    _SUP=$!
    set_status supervisor "$_SUP"
    log_msg "supervisor started: $_SUP (cwd=$MODDIR)"
fi

# --- 3. extras: detached, bounded, never able to block or fail the boot ------

(
    # 3.0 diagnostics: a nested detached subshell, so the 20s/60s sleeps can
    # never delay the probes below (let alone the core start).
    diag_start

    if [ -d "$LITE_DIR" ]; then
        _mirrored=0
        for _f in keybox.xml target.txt security_patch.txt hbk; do
            if mirror_to_lite "$_f"; then
                _mirrored=$((_mirrored + 1))
            fi
        done
        set_status lite "mirrored:$_mirrored/4"
    else
        set_status lite absent
    fi

    # 3a. daemon liveness
    _i=0
    _DAEMON=""
    while [ "$_i" -lt 15 ]; do
        _DAEMON=$(pid_of TEESimulator)
        [ -n "$_DAEMON" ] && break
        sleep 1
        _i=$((_i + 1))
    done
    if [ -n "$_DAEMON" ]; then
        set_status daemon "$_DAEMON"
        log_msg "daemon(TEESimulator) pid: $_DAEMON"
    else
        set_status daemon missing
        log_msg "TEESimulator daemon did not appear within 15s"
    fi

    # 3b. injection probe: one bounded observation, never a retry loop.
    # 6.0.21: injection completes a few seconds *after* the daemon starts (the
    # daemon retries internally). Sampling once at t+<1s recorded a false
    # "inject=fail" on every boot, which read as "TEE does not work". Poll for up
    # to 30s instead.
    if [ -n "$_DAEMON" ]; then _TRIES=15; else _TRIES=3; fi
    _i=0
    _INJ=unknown
    while [ "$_i" -lt "$_TRIES" ]; do
        _INJ=$(inject_state)
        [ "$_INJ" = ok ] && break
        sleep 2
        _i=$((_i + 1))
    done
    set_status inject "$_INJ"
    log_msg "inject=$_INJ (keystore2 pid: $(pid_of keystore2))"

    if [ -n "$_DAEMON" ] && ! kill -0 "$_DAEMON" 2>/dev/null; then
        set_status daemon_exit 1
        log_msg "daemon exited during the injection probe; see logcat -s TEESimulator"
    fi

    # 3c. hide_bootloader (module root, default on, same default as the .so)
    _HB_FLAG="$CONFIG_DIR/hide_bootloader_toggle"
    if [ ! -f "$_HB_FLAG" ] && [ -f "$CONFIG_DIR/hide_bootloader" ]; then
        _HB_FLAG="$CONFIG_DIR/hide_bootloader"
    fi
    _HB=1
    if [ -f "$_HB_FLAG" ]; then
        _HB=$(flag_value "$_HB_FLAG" 1)
    fi
    if [ "$_HB" != 1 ]; then
        set_status hide_bootloader skipped
        log_msg "hide_bootloader disabled by $_HB_FLAG"
    elif [ ! -f "$MODDIR/hide_bootloader.sh" ]; then
        set_status hide_bootloader missing
        log_msg "hide_bootloader.sh is not packaged"
    elif sh "$MODDIR/hide_bootloader.sh" >> "$BOOT_LOG" 2>&1; then
        set_status hide_bootloader done
        log_msg "hide_bootloader.sh applied"
    else
        set_status hide_bootloader fail
        log_msg "hide_bootloader.sh returned an error (recorded, not fatal)"
    fi

    # 3d. WebUI persisted toggles, after the daemon so `pm list packages` works
    # for the target.txt refresh. `--no-kbu`: the keybox auto-update is driven
    # from 3e, where the wait is bounded and the outcome is recorded.
    if [ -f "$MODDIR/core/webui.sh" ]; then
        if sh "$MODDIR/core/webui.sh" boot-apply --no-kbu >> "$BOOT_LOG" 2>&1; then
            set_status boot_apply ok
            log_msg "webui.sh boot-apply applied"
        else
            set_status boot_apply fail
            log_msg "webui.sh boot-apply returned an error (recorded, not fatal)"
        fi
    else
        set_status boot_apply absent
    fi

    # 3e. keybox auto-update (KSU has no kernel module to schedule it)
    _KBU=unavailable
    if [ -f "$MODDIR/core/webui.sh" ]; then
        _kbu_json=$(sh "$MODDIR/core/webui.sh" kbu_status 2>/dev/null)
        _kbu_enabled=$(printf '%s' "$_kbu_json" | sed -n 's/.*"enabled":\(true\).*/\1/p')
        _kbu_next=$(printf '%s' "$_kbu_json" | sed -n 's/.*"nextEpoch":\([0-9][0-9]*\).*/\1/p')
        _kbu_now=$(printf '%s' "$_kbu_json" | sed -n 's/.*"now":\([0-9][0-9]*\).*/\1/p')
        if [ "$_kbu_enabled" = true ]; then
            _KBU=not_due
            if [ -n "$_kbu_next" ] && [ -n "$_kbu_now" ] && [ "$_kbu_next" -le "$_kbu_now" ] 2>/dev/null; then
                _KBU=due
            fi
        else
            _KBU=disabled
        fi
        if [ "$_KBU" = due ]; then
            rm -f "$CONFIG_DIR/kbu_boot.rc" "$CONFIG_DIR/kbu_boot.out" 2>/dev/null
            ( sh "$MODDIR/core/webui.sh" kbu_now > "$CONFIG_DIR/kbu_boot.out" 2>> "$BOOT_LOG"; echo $? > "$CONFIG_DIR/kbu_boot.rc" ) &
            _n=0
            while [ "$_n" -lt 25 ]; do
                [ -f "$CONFIG_DIR/kbu_boot.rc" ] && break
                sleep 1
                _n=$((_n + 1))
            done
            if [ -f "$CONFIG_DIR/kbu_boot.rc" ]; then
                _rc=$(cat "$CONFIG_DIR/kbu_boot.rc" 2>/dev/null)
                if [ "$_rc" = 0 ] && grep -q '"ok":true' "$CONFIG_DIR/kbu_boot.out" 2>/dev/null; then
                    _KBU=ok
                    log_msg "keybox auto-update applied"
                else
                    _KBU=fail
                    log_msg "keybox auto-update failed: $(head -c 200 "$CONFIG_DIR/kbu_boot.out" 2>/dev/null)"
                fi
            else
                _KBU=timeout
                log_msg "keybox auto-update still running after 25s (left in background)"
            fi
            rm -f "$CONFIG_DIR/kbu_boot.rc" "$CONFIG_DIR/kbu_boot.out" 2>/dev/null
        fi
    fi
    set_status kbu "$_KBU"

    # 3f. logd size properties (upstream behaviour, bounded)
    _n=0
    while [ "$_n" -lt "$BOOT_WAIT_MAX" ]; do
        [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && break
        sleep 1
        _n=$((_n + 1))
    done
    # 6.0.21: the first boot-apply runs before PackageManagerService is ready, so
    # `pm list packages -3` can be empty and target.txt keeps its old contents
    # (that is why a freshly installed detector was missing from it). Refresh once
    # more after boot, then re-probe the injection so ksu_status reflects reality.
    if [ -f "$MODDIR/core/webui.sh" ]; then
        sh "$MODDIR/core/webui.sh" boot-apply --no-kbu >> "$BOOT_LOG" 2>&1             && log_msg "post-boot target refresh ok"             || log_msg "post-boot target refresh failed (recorded)"
    fi
    set_status inject "$(inject_state)"
    log_msg "post-boot inject=$(inject_state)"

    setprop persist.logd.size "" 2>/dev/null
    setprop persist.logd.size.crash "" 2>/dev/null
    setprop persist.logd.size.system "" 2>/dev/null
    setprop persist.logd.size.main "" 2>/dev/null

    # 6.0.29: the list must keep itself current, not only at boot. The watcher
    # refreshes every 30s (from early boot onwards, as soon as `pm` answers), keeps
    # user markers/comments and only rewrites the file when the content changed.
    if [ -f "$MODDIR/core/webui.sh" ]; then
        if command -v setsid >/dev/null 2>&1; then
            setsid sh "$MODDIR/core/webui.sh" target-watch 30 \
                </dev/null >> "$BOOT_LOG" 2>&1 &
        else
            sh "$MODDIR/core/webui.sh" target-watch 30 \
                </dev/null >> "$BOOT_LOG" 2>&1 &
        fi
        log_msg "target watcher started (interval 30s)"
    fi
    # 6.0.29: surface the target refresh result; "targets=11" in a report was
    # otherwise indistinguishable from "refresh never ran".
    set_status target_refresh "$(cat "$CONFIG_DIR/target_refresh" 2>/dev/null || echo unknown)"
    # 6.0.30: try to start saterserver before a client binds to it. Harmless when the
    # platform refuses (the injector still catches the process when a client starts it).
    if [ -f "$MODDIR/core/webui.sh" ]; then
        ( i=0
          while [ "$i" -lt 3 ]; do
              sleep 15
              sh "$MODDIR/core/webui.sh" soter-warm >> "$BOOT_LOG" 2>&1
              [ -n "$(pidof com.tencent.soter.soterserver 2>/dev/null)" ] && break
              i=$((i + 1))
          done ) &
        log_msg "soter warm-up scheduled"
    fi
    # resetprop-style modules may run later in boot and overwrite the boot props;
    # re-apply ours once after boot settles so the last writer is us.
    if [ -f "$MODDIR/hide_bootloader.sh" ] && [ -f "$CONFIG_DIR/hide_bootloader_toggle" ]; then
        if [ "$(tr -d ' \t\r\n' < "$CONFIG_DIR/hide_bootloader_toggle" 2>/dev/null)" != "0" ]; then
            ( sleep 45; sh "$MODDIR/hide_bootloader.sh" >> "$BOOT_LOG" 2>&1; \
              log_msg "hide_bootloader second pass done" ) &
        fi
    fi
    set_status done 1
    log_msg "extras done"
) >> "$BOOT_LOG" 2>&1 &

exit 0

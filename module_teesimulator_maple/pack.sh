#!/bin/sh
# 打包 SKRoot 模块 ZIP
# 用法：在本目录执行 ./pack.sh
# 需要：已经用 ndk-build 编出 libs/arm64-v8a/libmodule_teesimulator_maple.so
set -e

MODDIR=$(cd "$(dirname "$0")" && pwd)
cd "$MODDIR"

SO=""
for cand in \
    "libs/arm64-v8a/libmodule_teesimulator_maple.so" \
    "obj/local/arm64-v8a/libmodule_teesimulator_maple.so" \
    "build/libmodule_teesimulator_maple.so"
do
    if [ -f "$cand" ]; then SO="$cand"; break; fi
done

if [ -z "$SO" ]; then
    echo "!! 没有找到 libmodule_teesimulator_maple.so"
    echo "   请先在 jni 子目录里执行:  ndk-build"
    echo "   （需要 Android NDK r26d 及以上）"
    exit 1
fi

OUTNAME="module_TEESimulator_MapleSU_SKRoot.zip"
STAGE="build/package"
rm -rf "$STAGE"
mkdir -p "$STAGE"

# 1) 模块本体（.so 由 SKRoot 在 zygote64 之前加载）
cp "$SO" "$STAGE/libmodule_teesimulator_maple.so"

# 2) 核心负载：resources/ 下的内容会被框架释放到 module_private_dir
cp -r resources/. "$STAGE/"

# 3) WebUI 静态资源：官方示例包用的是 webroot/，SDK 注释里写的是 wwwroot/，
#    两个都带上，根目录再放一份 index.html 兜底（防文档根取错）。
if [ -d webroot ]; then cp -r webroot "$STAGE/"; fi
if [ -d wwwroot ]; then cp -r wwwroot "$STAGE/"; fi
if [ -f webroot/index.html ]; then cp webroot/index.html "$STAGE/index.html"; fi

# 4) 权限：脚本/二进制给执行位（框架安装时也会统一设置）
chmod 0755 "$STAGE/service.sh" "$STAGE/supervisor" "$STAGE/daemon" \
           "$STAGE/inject" "$STAGE/resetprop" "$STAGE/hide_bootloader.sh" \
           "$STAGE/core/webui.sh" 2>/dev/null || true
chmod 0644 "$STAGE/classes.dex" "$STAGE/libTEESimulator.so" \
           "$STAGE/libcertgen.so" "$STAGE/keybox.xml" "$STAGE/target.txt" \
           "$STAGE/sepolicy.rule" 2>/dev/null || true

# 5) 压包
rm -f "$OUTNAME"
if command -v zip >/dev/null 2>&1; then
    ( cd "$STAGE" && zip -qr "../../$OUTNAME" . )
else
    echo "!! 没找到 zip 命令（建议在装了 zip 的 Linux/CI 上打包）"
    exit 1
fi

echo "== 打包完成: $MODDIR/$OUTNAME"
ls -lh "$OUTNAME" 2>/dev/null || true

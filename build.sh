#!/bin/sh
# DLBox 构建脚本：编译 + 链接 + 打包未签名 IPA
# 依赖：clang19 + ld64.lld + iPhoneOS16.5.sdk
#
# 用法：
#   sh build.sh [期号] [步骤]
#     期号：写进版本号，默认 P5
#     步骤：1=编译 C  2=编译 ObjC  3=链接  4=打包，省略则全跑
#   例：sh build.sh P5 1
#
# 环境变量：
#   WITH_BT=1  把冻结的 BT 引擎（csrc/bt_*.c + DLBTSession + DLBTViewController）也编进去
#              默认 0：源码保留在仓库，但不参与编译，构建快、IPA 小
set -e

ROOT=$(cd "$(dirname "$0")" && pwd)
SDK=${SDK:-/workspace/iPhoneOS16.5.sdk}
CLANG=${CLANG:-/usr/lib/llvm19/bin/clang}
LD=${LD:-/usr/bin/ld64.lld}
MIN=14.0
NAME=DLBox
VER=${VER:-0.5.2}
STAGE="${1:-P5}"
STEP="${2:-all}"
WITH_BT="${WITH_BT:-0}"
WITH_LT="${WITH_LT:-1}"
LT_ROOT="${LT_ROOT:-/workspace/btport/prebuilt}"
BOOST_ROOT="${BOOST_ROOT:-/workspace/btport/boost_1_86_0}"
JOBS="${JOBS:-4}"

BUILD="$ROOT/build"
APP="$BUILD/Payload/$NAME.app"

if [ "$WITH_LT" = "1" ]; then
    for lib in libtorrent-rasterbar.a libssl.a libcrypto.a; do
        if [ ! -f "$LT_ROOT/lib/$lib" ]; then
            echo "!! WITH_LT=1 但找不到 $LT_ROOT/lib/$lib"
            echo "   装上预编译库，或 WITH_LT=0 sh build.sh <期号> 只编 HTTP / 爬虫"
            exit 1
        fi
    done
fi

CFLAGS="-target arm64-apple-ios$MIN -isysroot $SDK -fobjc-arc -fblocks -O1 -Wall -Wno-unused-parameter -DDLBOX_WITH_BT=$WITH_BT -DDLBOX_WITH_LT=$WITH_LT -I$ROOT/src -I$ROOT/csrc -F$SDK/System/Cryptexes/OS/System/Library/Frameworks"
CXXFLAGS="-target arm64-apple-ios$MIN -isysroot $SDK -fobjc-arc -fblocks -std=c++17 -O1 -Wall -Wno-unused-parameter -Wno-deprecated-declarations -DTORRENT_NO_DEPRECATE -DTORRENT_HAVE_MMAP=0 -DDLBOX_WITH_BT=$WITH_BT -DDLBOX_WITH_LT=$WITH_LT -I$ROOT/src -I$ROOT/csrc -I$LT_ROOT/include -I$BOOST_ROOT -I$SDK/usr/include/pthread -F$SDK/System/Cryptexes/OS/System/Library/Frameworks"

CCFLAGS="-target arm64-apple-ios$MIN -isysroot $SDK -O1 -Wall -Wextra -Wno-unused-parameter -DDLBOX_WITH_BT=$WITH_BT -I$ROOT/csrc"

if [ "$STEP" = "1" ] || [ "$STEP" = "all" ]; then
    rm -rf "$BUILD"
fi
mkdir -p "$APP" "$BUILD/obj"

# ---------- 1. 编译 C ----------
if [ "$STEP" = "1" ] || [ "$STEP" = "all" ]; then
    if [ "$WITH_BT" = "1" ]; then
        echo "==> 编译 C（BT 引擎）"
    else
        echo "==> 编译 C（BT 引擎已冻结，跳过 csrc/bt_*.c）"
    fi
    for f in "$ROOT"/csrc/*.c; do
        [ -e "$f" ] || continue
        b=$(basename "$f")
        if [ "$WITH_BT" != "1" ]; then
            case "$b" in
                bt_*) echo "    跳过 $b"; continue ;;
            esac
        fi
        o="$BUILD/obj/${b%.c}.o"
        "$CLANG" $CCFLAGS -c "$f" -o "$o"
    done
fi

# ---------- 2. 编译 ObjC ----------
if [ "$STEP" = "2" ] || [ "$STEP" = "all" ]; then
    echo "==> 编译 ObjC（BT=$WITH_BT，并发 $JOBS）"
    PIDS=""
    RUNNING=0
    for f in "$ROOT"/src/*.m "$ROOT"/src/*.mm; do
        [ -e "$f" ] || continue
        b=$(basename "$f")
        if [ "$WITH_BT" != "1" ]; then
            case "$b" in
                DLBTSession.m|DLBTViewController.m)
                    echo "    跳过 $b（BT 已冻结，WITH_BT=0）"
                    continue ;;
            esac
        fi
        case "$b" in
            *.mm) o="$BUILD/obj/${b%.mm}.o"; "$CLANG" $CXXFLAGS -c "$f" -o "$o" & ;;
            *)    o="$BUILD/obj/${b%.m}.o";  "$CLANG" $CFLAGS  -c "$f" -o "$o" & ;;
        esac
        PIDS="$PIDS $!"
        RUNNING=$((RUNNING + 1))
        if [ "$RUNNING" -ge "$JOBS" ]; then
            for p in $PIDS; do
                if ! wait "$p"; then
                    for q in $PIDS; do kill "$q" 2>/dev/null || true; done
                    exit 1
                fi
            done
            PIDS=""
            RUNNING=0
        fi
    done
    for p in $PIDS; do
        if ! wait "$p"; then
            for q in $PIDS; do kill "$q" 2>/dev/null || true; done
            exit 1
        fi
    done
fi

# ---------- 3. 链接 ----------
if [ "$STEP" = "3" ] || [ "$STEP" = "all" ]; then
    echo "==> 链接"
    OBJS=$(ls "$BUILD"/obj/*.o 2>/dev/null | tr '\n' ' ')
    LT_LIBS=""
    if [ "$WITH_LT" = "1" ] && [ -f "$LT_ROOT/lib/libtorrent-rasterbar.a" ]; then
        LT_LIBS="$LT_ROOT/lib/libtorrent-rasterbar.a $LT_ROOT/lib/libssl.a $LT_ROOT/lib/libcrypto.a $SDK/usr/lib/libc++.1.tbd $SDK/usr/lib/libc++abi.tbd $SDK/usr/lib/libz.1.tbd $SDK/usr/lib/libiconv.2.tbd"
        echo "    链接 libtorrent: $LT_ROOT/lib/libtorrent-rasterbar.a"
    fi
    if [ -z "$OBJS" ]; then
        echo "!! build/obj 里没有目标文件，先跑步骤 1 / 2"
        exit 1
    fi
    "$LD" -arch arm64 -platform_version ios $MIN 16.5 -syslibroot "$SDK" \
        -e _main -o "$APP/$NAME" \
        "$SDK/usr/lib/libSystem.B.tbd" \
        -F"$SDK/System/Library/Frameworks" \
        -F"$SDK/System/Cryptexes/OS/System/Library/Frameworks" \
        -framework UIKit -framework Foundation -framework CoreGraphics -framework WebKit \
        -framework Security -framework CoreFoundation -framework SystemConfiguration \
        $OBJS \
        $LT_LIBS
    chmod 755 "$APP/$NAME"
    echo "    产物 $(ls -lh "$APP/$NAME" | awk '{print $5}')"
fi

# ---------- 4. 打包 ----------
if [ "$STEP" = "4" ] || [ "$STEP" = "all" ]; then
    echo "==> 复制资源并写入版本号（$VER ($STAGE)）"
    cp "$ROOT/res/Info.plist" "$APP/Info.plist"
    cp "$ROOT"/res/AppIcon*.png "$APP/" 2>/dev/null || true
    sed -i "/<key>CFBundleShortVersionString<\/key>/{n;s|<string>.*</string>|<string>$VER ($STAGE)</string>|;}" "$APP/Info.plist"
    sed -i "/<key>CFBundleVersion<\/key>/{n;s|<string>.*</string>|<string>$STAGE</string>|;}" "$APP/Info.plist"

    echo "==> 打包 IPA"
    IPA_DIR="/workspace/ipa"
    mkdir -p "$IPA_DIR"
    OUT="$IPA_DIR/$NAME-$STAGE.ipa"
    cd "$BUILD"
    rm -f "$OUT"
    zip -rq "$OUT" Payload
    VER_IN_IPA=$(sed -n '/<key>CFBundleShortVersionString<\/key>/{n;s|.*<string>\(.*\)</string>.*|\1|p;}' "$APP/Info.plist")
    if [ "$VER_IN_IPA" != "$VER ($STAGE)" ]; then
        echo "!! 版本号没写进 Info.plist：期望「$VER ($STAGE)」，实际「$VER_IN_IPA」"
        exit 1
    fi
    echo "    版本自检通过：$VER_IN_IPA"
    echo "完成 → $OUT"
    ls -lh "$OUT"
fi

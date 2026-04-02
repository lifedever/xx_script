#!/bin/bash
# BoxX v2 构建安装脚本
# 用法: ./build.sh [clean|install|run|uninstall]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="BoxX"
BUNDLE_ID="com.boxx.app"
INSTALL_DIR="/Applications"
SCHEME="BoxX"
# 固定 DerivedData 路径，避免 Xcode 默认路径不可预测
DERIVED_DATA="$SCRIPT_DIR/.build/DerivedData"

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}✅ $1${NC}"; }
warn()  { echo -e "${YELLOW}⚠️  $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; }
step()  { echo -e "${CYAN}→ $1${NC}"; }

# 构建产物的确定性路径
get_build_dir() {
    echo "$DERIVED_DATA/Build/Products/Release"
}

# 停止 BoxX 进程（保留 sing-box 服务不中断）
stop_all() {
    step "停止 BoxX 进程..."

    # 1. 先写一个信号文件，告诉新启动的 BoxX 跳过"意外停止"通知
    touch /tmp/boxx-upgrading

    # 2. 直接 SIGKILL — 因为 BoxX 的 applicationShouldTerminate 会拦截 SIGTERM
    #    不能用 SIGTERM，否则 app 只会隐藏窗口而不退出
    pkill -9 -x BoxX 2>/dev/null || true
    sleep 0.5

    # 3. 验证已退出
    if pgrep -x BoxX >/dev/null 2>&1; then
        warn "BoxX 进程仍在运行，重试..."
        killall -9 BoxX 2>/dev/null || true
        sleep 1
    fi

    if pgrep -x BoxX >/dev/null 2>&1; then
        error "无法停止 BoxX 进程"
        exit 1
    fi

    info "BoxX 进程已停止（sing-box 服务保持运行）"
}

# 生成 Xcode 项目
generate() {
    step "生成 Xcode 项目..."
    if ! command -v xcodegen &>/dev/null; then
        error "xcodegen 未安装，请运行: brew install xcodegen"
        exit 1
    fi
    cd "$SCRIPT_DIR"
    xcodegen generate --quiet
    info "项目已生成"
}

# 递增版本号 (CFBundleShortVersionString: x.y 格式，每次 +1.0)
bump_version() {
    local plist="$SCRIPT_DIR/BoxX/Info.plist"
    local current
    current=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$plist" 2>/dev/null || echo "0.0")
    # Extract major part and increment
    local major minor
    major=$(echo "$current" | cut -d. -f1)
    minor=$(echo "$current" | cut -d. -f2)
    local new_minor=$((minor + 1))
    local new_version="${major}.${new_minor}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $new_version" "$plist"
    # Also bump build number
    local build_num
    build_num=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$plist" 2>/dev/null || echo "0")
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((build_num + 1))" "$plist"
    info "版本号: $current → $new_version (build $((build_num + 1)))"
}

# 构建
build() {
    step "构建 $APP_NAME (Release)..."
    cd "$SCRIPT_DIR"

    BUILD_DIR=$(get_build_dir)

    xcodebuild build \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$DERIVED_DATA" \
        ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
        -quiet \
        2>&1 | tail -5

    if [ -d "$BUILD_DIR/$APP_NAME.app" ]; then
        info "构建成功: $BUILD_DIR/$APP_NAME.app"
    else
        error "构建失败：找不到 $BUILD_DIR/$APP_NAME.app"
        exit 1
    fi
}

# 注册 Helper 服务到 launchd
register_helper() {
    step "注册 Helper 服务..."

    local HELPER_SRC="$INSTALL_DIR/$APP_NAME.app/Contents/Library/LaunchDaemons/BoxXHelper"
    local HELPER_DST="/Library/PrivilegedHelperTools/com.boxx.helper"
    local PLIST_DST="/Library/LaunchDaemons/com.boxx.helper.plist"
    local LEGACY_PLIST="/Library/LaunchDaemons/com.boxx.singbox.plist"
    local LEGACY_SUDOERS="/etc/sudoers.d/boxx-singbox"

    if [ ! -f "$HELPER_SRC" ]; then
        error "Helper 二进制不存在: $HELPER_SRC"
        return 1
    fi

    # 卸载旧版 Helper（如已注册）
    sudo launchctl bootout system/com.boxx.helper 2>/dev/null || true
    sleep 0.5

    # 迁移：卸载旧版 sing-box daemon
    if [ -f "$LEGACY_PLIST" ]; then
        step "迁移旧版 sing-box daemon..."
        sudo launchctl bootout system/com.boxx.singbox 2>/dev/null || true
        sudo rm -f "$LEGACY_PLIST"
        info "旧版 daemon 已移除"
    fi
    if [ -f "$LEGACY_SUDOERS" ]; then
        sudo rm -f "$LEGACY_SUDOERS"
        info "旧版 sudoers 规则已移除"
    fi

    # 创建目标目录
    sudo mkdir -p /Library/PrivilegedHelperTools

    # 复制 Helper 二进制
    sudo cp "$HELPER_SRC" "$HELPER_DST"
    sudo chmod 755 "$HELPER_DST"
    sudo chown root:wheel "$HELPER_DST"

    # 写入 launchd plist
    sudo tee "$PLIST_DST" > /dev/null << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.boxx.helper</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Library/PrivilegedHelperTools/com.boxx.helper</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>com.boxx.helper</key>
        <true/>
    </dict>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
PLIST
    sudo chmod 644 "$PLIST_DST"
    sudo chown root:wheel "$PLIST_DST"

    # 注册到 launchd
    sudo launchctl bootstrap system "$PLIST_DST"

    # 验证
    sleep 1
    if sudo launchctl print system/com.boxx.helper >/dev/null 2>&1; then
        info "Helper 服务已注册并运行"
    else
        warn "Helper 服务注册可能失败，请检查 sudo launchctl list | grep boxx"
    fi
}

# 卸载 Helper 服务
unregister_helper() {
    step "卸载 Helper 服务..."
    sudo launchctl bootout system/com.boxx.helper 2>/dev/null || true
    sudo rm -f /Library/LaunchDaemons/com.boxx.helper.plist
    sudo rm -f /Library/PrivilegedHelperTools/com.boxx.helper
    info "Helper 服务已卸载"
}

# 安装到 /Applications
install_app() {
    BUILD_DIR=$(get_build_dir)

    if [ ! -d "$BUILD_DIR/$APP_NAME.app" ]; then
        error "找不到构建产物，请先运行 ./build.sh build"
        exit 1
    fi

    step "安装到 $INSTALL_DIR/$APP_NAME.app ..."

    # 停止旧进程
    stop_all

    # 移除旧版
    if [ -d "$INSTALL_DIR/$APP_NAME.app" ]; then
        rm -rf "$INSTALL_DIR/$APP_NAME.app"
        info "已移除旧版"
    fi

    # 复制新版
    cp -R "$BUILD_DIR/$APP_NAME.app" "$INSTALL_DIR/$APP_NAME.app"

    # 刷新 Launch Services 缓存，确保 macOS 识别新版本
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null || true

    # 验证安装版本
    local installed_version
    installed_version=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$INSTALL_DIR/$APP_NAME.app/Contents/Info.plist" 2>/dev/null || echo "?")
    info "已安装到 $INSTALL_DIR/$APP_NAME.app (build $installed_version)"
}

# 启动
launch() {
    step "启动 $APP_NAME ..."
    # 必须用 -n 强制启动新实例，-F 清除 Saved Application State 缓存
    open -n -F "$INSTALL_DIR/$APP_NAME.app"
    sleep 1
    # 验证新版本确实在运行
    local running_pid
    running_pid=$(pgrep -x BoxX 2>/dev/null || true)
    if [ -n "$running_pid" ]; then
        info "$APP_NAME 已启动 (PID: $running_pid)"
    else
        warn "$APP_NAME 启动可能延迟，请检查"
    fi
    # 清理升级信号文件
    rm -f /tmp/boxx-upgrading
}

# 卸载
uninstall() {
    step "卸载 $APP_NAME ..."
    stop_all
    # 停止 sing-box
    sudo pkill -x sing-box 2>/dev/null || true
    # 卸载 Helper
    unregister_helper
    # 卸载旧版 daemon（如果存在）
    sudo launchctl bootout system/com.boxx.singbox 2>/dev/null || true
    sudo rm -f /Library/LaunchDaemons/com.boxx.singbox.plist
    sudo rm -f /etc/sudoers.d/boxx-singbox
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
    info "已从 $INSTALL_DIR 移除"
    echo "  配置目录保留在: ~/Library/Application Support/BoxX/"
    echo "  如需完全清理: rm -rf ~/Library/Application\\ Support/BoxX/"
}

# 清理构建缓存
clean() {
    step "清理构建缓存..."
    cd "$SCRIPT_DIR"
    rm -rf "$DERIVED_DATA"
    rm -rf "$SCRIPT_DIR/BoxX.xcodeproj"
    info "已清理"
}

# 完整流程：清理 → 生成 → 构建 → 安装 → 启动
full() {
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo -e "${BOLD}  BoxX v2 构建安装${NC}"
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo ""

    # 必须清理 DerivedData，否则 xcodegen 重新生成 xcodeproj 后
    # xcodebuild 增量编译可能用缓存的旧产物，导致新代码没装上去
    step "清理构建缓存..."
    rm -rf "$DERIVED_DATA"

    bump_version
    generate
    build
    install_app
    register_helper
    launch

    echo ""
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    info "全部完成！BoxX 已安装到 $INSTALL_DIR 并启动"
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
}

# 打包 DMG
pack() {
    BUILD_DIR=$(get_build_dir)

    if [ ! -d "$BUILD_DIR/$APP_NAME.app" ]; then
        error "找不到构建产物，请先运行 ./build.sh build"
        exit 1
    fi

    local VERSION
    VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$SCRIPT_DIR/BoxX/Info.plist" 2>/dev/null || echo "0.0")
    local DIST_DIR="$SCRIPT_DIR/dist"
    local DMG_NAME="BoxX-v${VERSION}.dmg"
    local TMP_DIR=$(mktemp -d)

    step "打包 DMG: $DMG_NAME ..."

    mkdir -p "$DIST_DIR"
    # 删除所有旧版 DMG
    rm -f "$DIST_DIR"/BoxX-v*.dmg

    # 准备临时目录
    cp -R "$BUILD_DIR/$APP_NAME.app" "$TMP_DIR/$APP_NAME.app"

    # 创建 Applications 快捷方式
    ln -s /Applications "$TMP_DIR/Applications"

    # 创建 DMG
    hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$TMP_DIR" \
        -ov \
        -format UDZO \
        "$DIST_DIR/$DMG_NAME" \
        -quiet

    # 清理
    rm -rf "$TMP_DIR"

    info "DMG 已生成: $DIST_DIR/$DMG_NAME"
    open "$DIST_DIR"
}

# 主入口
case "${1:-full}" in
    clean)      clean ;;
    generate)   generate ;;
    build)      generate && build ;;
    install)    install_app ;;
    run|launch) launch ;;
    uninstall)  uninstall ;;
    pack|dmg)   bump_version && generate && build && pack ;;
    full|"")    full ;;
    *)
        echo "用法: $0 [命令]"
        echo ""
        echo "命令:"
        echo "  full       完整流程: 生成→构建→安装→启动 (默认)"
        echo "  build      生成项目并构建"
        echo "  install    安装到 /Applications"
        echo "  run        启动应用"
        echo "  pack       构建并打包 DMG 到 dist/"
        echo "  clean      清理构建缓存"
        echo "  uninstall  卸载应用"
        ;;
esac

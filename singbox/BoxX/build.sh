#!/bin/bash
# BoxX v2 构建安装脚本
# 用法: ./build.sh [clean|install|run|uninstall]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="BoxX"
BUNDLE_ID="com.boxx.app"
INSTALL_DIR="/Applications"
SCHEME="BoxX"

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

# 获取构建产物路径
get_build_dir() {
    xcodebuild -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
        | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $3}'
}

# 停止所有 BoxX 相关进程
stop_all() {
    step "停止 BoxX 相关进程..."
    pkill -x BoxX 2>/dev/null || true
    pkill -x sing-box 2>/dev/null || true
    # 等待端口释放
    for i in $(seq 1 30); do
        if ! lsof -i :7890 -i :9091 &>/dev/null; then
            break
        fi
        sleep 0.2
    done
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

# 构建
build() {
    step "构建 $APP_NAME (Release)..."
    cd "$SCRIPT_DIR"

    xcodebuild build \
        -scheme "$SCHEME" \
        -configuration Release \
        -destination 'platform=macOS' \
        -quiet \
        2>&1 | tail -5

    BUILD_DIR=$(get_build_dir | sed 's/Debug/Release/')

    if [ ! -d "$BUILD_DIR/$APP_NAME.app" ]; then
        # Fallback to Debug
        BUILD_DIR=$(get_build_dir)
        xcodebuild build \
            -scheme "$SCHEME" \
            -configuration Debug \
            -destination 'platform=macOS' \
            -quiet \
            2>&1 | tail -5
    fi

    if [ -d "$BUILD_DIR/$APP_NAME.app" ]; then
        info "构建成功: $BUILD_DIR/$APP_NAME.app"
    else
        error "构建失败"
        exit 1
    fi
}

# 安装到 /Applications
install_app() {
    BUILD_DIR=$(get_build_dir | sed 's/Debug/Release/')
    [ ! -d "$BUILD_DIR/$APP_NAME.app" ] && BUILD_DIR=$(get_build_dir)

    if [ ! -d "$BUILD_DIR/$APP_NAME.app" ]; then
        error "找不到构建产物，请先运行 ./build.sh"
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
    info "已安装到 $INSTALL_DIR/$APP_NAME.app"
}

# 启动
launch() {
    step "启动 $APP_NAME ..."
    open "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null \
        || open "$BUILD_DIR/$APP_NAME.app" 2>/dev/null \
        || open "$(get_build_dir)/$APP_NAME.app"
    info "$APP_NAME 已启动"
}

# 卸载
uninstall() {
    step "卸载 $APP_NAME ..."
    stop_all
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
    info "已从 $INSTALL_DIR 移除"
    echo "  配置目录保留在: ~/Library/Application Support/BoxX/"
    echo "  如需完全清理: rm -rf ~/Library/Application\\ Support/BoxX/"
}

# 清理构建缓存
clean() {
    step "清理构建缓存..."
    cd "$SCRIPT_DIR"
    xcodebuild clean -scheme "$SCHEME" -quiet 2>/dev/null || true
    rm -rf "$SCRIPT_DIR/BoxX.xcodeproj"
    info "已清理"
}

# 完整流程：清理 → 生成 → 构建 → 安装 → 启动
full() {
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo -e "${BOLD}  BoxX v2 构建安装${NC}"
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    echo ""

    generate
    build
    install_app
    launch

    echo ""
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
    info "全部完成！BoxX 已安装到 $INSTALL_DIR 并启动"
    echo -e "${BOLD}═══════════════════════════════════════${NC}"
}

# 主入口
case "${1:-full}" in
    clean)      clean ;;
    generate)   generate ;;
    build)      generate && build ;;
    install)    install_app ;;
    run|launch) launch ;;
    uninstall)  uninstall ;;
    full|"")    full ;;
    *)
        echo "用法: $0 [命令]"
        echo ""
        echo "命令:"
        echo "  full       完整流程: 生成→构建→安装→启动 (默认)"
        echo "  build      生成项目并构建"
        echo "  install    安装到 /Applications"
        echo "  run        启动应用"
        echo "  clean      清理构建缓存"
        echo "  uninstall  卸载应用"
        ;;
esac

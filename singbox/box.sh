#!/bin/bash
# sing-box 管理脚本
# 用法: box <命令>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG="$SCRIPT_DIR/config.json"
PID_FILE="$SCRIPT_DIR/.sing-box.pid"
LOG_FILE="$SCRIPT_DIR/sing-box.log"
CACHE_FILE="$SCRIPT_DIR/cache.db"
PANEL_URL="https://yacd.metacubex.one"
API_ADDR="127.0.0.1:9091"
PROXY_PORT=7890

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

is_running() {
    sudo pgrep -f "sing-box run" &>/dev/null
}

get_pid() {
    sudo pgrep -f "sing-box run" 2>/dev/null
}

start() {
    if is_running; then
        warn "sing-box 已在运行 (PID: $(get_pid))"
        return 1
    fi
    if [ ! -f "$CONFIG" ]; then
        error "配置文件不存在，先运行: box generate"
        return 1
    fi
    echo -e "${CYAN}🚀 启动 sing-box...${NC}"
    sudo true || { error "sudo 认证失败"; return 1; }
    echo -e "\n===== $(date '+%Y-%m-%d %H:%M:%S') sing-box start =====" >> "$LOG_FILE"
    sudo sing-box run -c "$CONFIG" >> "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 2
    if is_running; then
        info "sing-box 已启动 (PID: $(get_pid))"
        echo -e "   代理端口: ${BOLD}$PROXY_PORT${NC} (HTTP + SOCKS5)"
        echo -e "   管理面板: ${BOLD}$PANEL_URL${NC}"
        echo -e "   后端地址: ${BOLD}http://$API_ADDR${NC}"
    else
        error "启动失败"
        echo "   查看日志: box log"
        rm -f "$PID_FILE"
        return 1
    fi
}

stop() {
    sudo true 2>/dev/null
    local pids=$(get_pid)
    if [ -n "$pids" ]; then
        echo -e "${CYAN}🛑 停止 sing-box...${NC}"
        sudo kill $pids 2>/dev/null
        sleep 1
        sudo kill -9 $pids 2>/dev/null
        rm -f "$PID_FILE"
        info "已停止"
    else
        echo -e "⏹  sing-box 未在运行"
    fi
}

restart() {
    stop
    sleep 1
    start
}

status() {
    if is_running; then
        info "sing-box 运行中 (PID: $(get_pid))"
        echo -e "   代理端口: ${BOLD}$PROXY_PORT${NC} (HTTP + SOCKS5)"
        echo -e "   管理面板: ${BOLD}$PANEL_URL${NC}"
        echo -e "   后端地址: ${BOLD}http://$API_ADDR${NC}"
        # 显示活跃连接数
        local conns=$(curl -s "http://$API_ADDR/connections" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('connections',[])))" 2>/dev/null)
        [ -n "$conns" ] && echo -e "   活跃连接: ${BOLD}$conns${NC}"
        echo ""
        # 订阅和节点统计
        python3 -c "
import json
with open('$CONFIG') as f:
    d = json.load(f)
obs = d.get('outbounds', [])
nodes = [o for o in obs if o['type'] not in ('direct', 'selector', 'urltest', 'block', 'dns')]
subs = {}
selectors = [o for o in obs if o['type'] == 'selector' and o['tag'].startswith('📦')]
for s in selectors:
    subs[s['tag']] = len(s.get('outbounds', []))
regions = [o for o in obs if o['type'] == 'selector' and o['tag'][0] in '🇭🇨🇯🇰🇸🇺🌍']
print(f'\033[1m订阅信息:\033[0m')
for name, count in subs.items():
    print(f'   {name}  {count} 个节点')
print(f'   总计: {len(nodes)} 个节点')
print()
print(f'\033[1m地区分组:\033[0m')
for r in regions:
    print(f'   {r[\"tag\"]}  {len(r.get(\"outbounds\", []))} 个节点')
" 2>/dev/null
        echo ""
        echo -e "${BOLD}分流规则 (按优先级从高到低):${NC}"
        echo -e "   ${GREEN}DIRECT${NC}      内网/自有域名 (manyibar, kanasinfo 等)"
        echo -e "   ${GREEN}DIRECT${NC}      私有地址 (192.168.x.x, 10.x.x.x 等)"
        echo -e "   ${RED}REJECT${NC}      广告拦截 (geosite-ads)"
        echo -e "   ${CYAN}🤖 OpenAI${NC}   AI 服务 (Claude, ChatGPT, Gemini 等)"
        echo -e "   ${CYAN}▶️  YouTube${NC}  YouTube"
        echo -e "   ${CYAN}🎬 Netflix${NC}  Netflix"
        echo -e "   ${CYAN}🏰 Disney${NC}   Disney+"
        echo -e "   ${CYAN}🎵 TikTok${NC}   TikTok"
        echo -e "   ${CYAN}🔍 Google${NC}   Google"
        echo -e "   ${CYAN}💻 Microsoft${NC} Microsoft + GitHub"
        echo -e "   ${CYAN}📝 Notion${NC}   Notion"
        echo -e "   ${CYAN}🍎 Apple${NC}    Apple 服务 (默认 DIRECT)"
        echo -e "   ${CYAN}Proxy${NC}       非中国域名 (geosite-geolocation-!cn)"
        echo -e "   ${GREEN}DIRECT${NC}      中国域名 + 中国 IP (geosite-cn + geoip-cn)"
        echo -e "   ${YELLOW}🐟 漏网之鱼${NC}  以上都未匹配 (默认走 Proxy)"
    else
        echo -e "⏹  sing-box 未运行"
    fi
}

generate() {
    echo -e "${CYAN}📦 生成配置...${NC}"
    python3 "$SCRIPT_DIR/generate.py"
}

update() {
    generate || { error "生成配置失败"; return 1; }
    echo ""
    if is_running; then
        restart
    else
        start
    fi
}

log() {
    if [ -f "$LOG_FILE" ]; then
        local lines=${1:-50}
        tail -"$lines" "$LOG_FILE"
    else
        echo "ℹ️  暂无日志"
    fi
}

logf() {
    if [ -f "$LOG_FILE" ]; then
        tail -f "$LOG_FILE"
    else
        echo "ℹ️  暂无日志"
    fi
}

panel() {
    if is_running; then
        echo -e "🌐 打开管理面板..."
        open "$PANEL_URL"
    else
        warn "sing-box 未运行，先执行: box start"
    fi
}

conns() {
    if ! is_running; then
        warn "sing-box 未运行"
        return 1
    fi
    local filter="${1:-}"
    curl -s "http://$API_ADDR/connections" 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
conns = d.get('connections', [])
f = '$filter'.lower()
print(f'活跃连接: {len(conns)} 个')
print(f'{'─' * 100}')
print(f'{\"域名\":<40s} {\"规则\":<25s} {\"出站\":<20s} {\"链路\"}')
print(f'{'─' * 100}')
for c in conns:
    meta = c.get('metadata', {})
    host = meta.get('host') or meta.get('destinationIP', '')
    chains = c.get('chains', [])
    chain = ' → '.join(chains)
    rule = c.get('rule', '')
    if f and f not in host.lower() and f not in chain.lower() and f not in rule.lower():
        continue
    print(f'{host:<40s} {rule:<25s} {chains[0] if chains else \"\":<20s} {chain}')
" 2>/dev/null
}

fix() {
    echo -e "${CYAN}🔧 修复网络...${NC}"
    # 刷新 DNS 缓存
    sudo dscacheutil -flushcache 2>/dev/null
    sudo killall -HUP mDNSResponder 2>/dev/null
    # 重启 sing-box
    if is_running; then
        restart
    else
        start
    fi
    info "网络已修复"
}

build() {
    local BOXX_DIR="$SCRIPT_DIR/BoxX"
    if [ ! -f "$BOXX_DIR/project.yml" ]; then
        error "BoxX 项目不存在: $BOXX_DIR"
        return 1
    fi
    echo -e "${CYAN}🔨 编译 BoxX...${NC}"
    cd "$BOXX_DIR"
    xcodegen generate -q 2>/dev/null
    if ! xcodebuild -scheme BoxX -configuration Debug build 2>&1 | tail -3 | grep -q "BUILD SUCCEEDED"; then
        error "编译失败"
        return 1
    fi
    # 找到编译产物并复制到 /Applications
    local BUILD_DIR=$(xcodebuild -scheme BoxX -configuration Debug -showBuildSettings 2>/dev/null | grep " BUILT_PRODUCTS_DIR" | awk '{print $3}')
    if [ ! -d "$BUILD_DIR/BoxX.app" ]; then
        error "编译产物不存在"
        return 1
    fi
    echo -e "${CYAN}📦 安装到 /Applications...${NC}"
    pkill -f "BoxX.app" 2>/dev/null
    sleep 1
    rm -rf /Applications/BoxX.app
    cp -R "$BUILD_DIR/BoxX.app" /Applications/
    info "BoxX 已安装到 /Applications/BoxX.app"
    echo -e "   启动: ${BOLD}open /Applications/BoxX.app${NC}"
    # 自动启动
    open /Applications/BoxX.app
    info "BoxX 已启动"
}

help() {
    echo -e "${BOLD}sing-box 管理脚本${NC}"
    echo ""
    echo -e "${BOLD}用法:${NC} box <命令> [参数]"
    echo ""
    echo -e "${BOLD}基础命令:${NC}"
    echo -e "  ${GREEN}start${NC}          启动 sing-box (TUN 全局模式)"
    echo -e "  ${GREEN}stop${NC}           停止 sing-box"
    echo -e "  ${GREEN}restart${NC}        重启 sing-box"
    echo -e "  ${GREEN}status${NC}         查看运行状态"
    echo ""
    echo -e "${BOLD}配置命令:${NC}"
    echo -e "  ${GREEN}generate${NC}       重新拉取订阅并生成配置"
    echo -e "  ${GREEN}update${NC}         生成配置 + 自动重启 (一键更新)"
    echo ""
    echo -e "${BOLD}维护命令:${NC}"
    echo -e "  ${GREEN}fix${NC}            修复网络 (休眠后断网时使用)"
    echo -e "  ${GREEN}build${NC}          编译 BoxX 并安装到 /Applications"
    echo ""
    echo -e "${BOLD}调试命令:${NC}"
    echo -e "  ${GREEN}log${NC}  [行数]    查看最近日志 (默认 50 行)"
    echo -e "  ${GREEN}logf${NC}           实时跟踪日志 (Ctrl+C 退出)"
    echo -e "  ${GREEN}conns${NC} [关键词]  查看活跃连接 (可过滤域名)"
    echo -e "  ${GREEN}panel${NC}          打开 Web 管理面板"
    echo ""
    echo -e "${BOLD}示例:${NC}"
    echo -e "  box start              # 启动"
    echo -e "  box update             # 更新订阅并重启"
    echo -e "  box build              # 编译并安装 BoxX 客户端"
    echo -e "  box conns google       # 查看 google 相关连接"
    echo -e "  box conns anthropic    # 查看 Claude 走了哪个节点"
    echo -e "  box log 100            # 查看最近 100 行日志"
}

case "${1:-help}" in
    start)    start ;;
    stop)     stop ;;
    restart)  restart ;;
    status)   status ;;
    generate) generate ;;
    update)   update ;;
    fix)      fix ;;
    build)    build ;;
    log)      log "$2" ;;
    logf)     logf ;;
    panel)    panel ;;
    conns)    conns "$2" ;;
    help|-h|--help) help ;;
    *)
        error "未知命令: $1"
        echo ""
        help
        ;;
esac

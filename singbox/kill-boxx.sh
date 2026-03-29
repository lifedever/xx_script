#!/bin/bash
# kill-boxx.sh — 终止 BoxX App 及其管理的 sing-box 进程
# 用于切换回 box.sh 管理时清理残留进程

echo "=== 清理 BoxX 相关进程 ==="

# 1. 关闭 BoxX App
if pgrep -x BoxX > /dev/null 2>&1; then
    echo "→ 终止 BoxX App..."
    pkill -x BoxX
    sleep 1
    # 强制杀掉如果还在
    if pgrep -x BoxX > /dev/null 2>&1; then
        echo "  强制终止 BoxX..."
        pkill -9 -x BoxX
    fi
    echo "  ✓ BoxX 已终止"
else
    echo "  BoxX 未运行"
fi

# 2. 关闭 sing-box（BoxX 启动的用户态进程）
if pgrep -x sing-box > /dev/null 2>&1; then
    echo "→ 终止 sing-box..."
    pkill -x sing-box
    sleep 1
    if pgrep -x sing-box > /dev/null 2>&1; then
        echo "  强制终止 sing-box..."
        pkill -9 -x sing-box
    fi
    echo "  ✓ sing-box 已终止"
else
    echo "  sing-box 未运行"
fi

# 3. 等待端口释放
echo "→ 等待端口释放..."
for i in $(seq 1 30); do
    if ! lsof -i :7890 > /dev/null 2>&1 && ! lsof -i :9091 > /dev/null 2>&1; then
        echo "  ✓ 端口 7890/9091 已释放"
        break
    fi
    sleep 0.2
done

# 检查是否还有残留
if lsof -i :7890 > /dev/null 2>&1 || lsof -i :9091 > /dev/null 2>&1; then
    echo "  ⚠ 端口仍被占用:"
    lsof -i :7890 -i :9091 2>/dev/null | head -5
    echo "  可能需要 sudo kill"
fi

echo ""
echo "=== 清理完成 ==="
echo "现在可以安全启动 box.sh：./box.sh start"

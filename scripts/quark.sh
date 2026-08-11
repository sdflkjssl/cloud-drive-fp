#!/usr/bin/env bash
# 夸克网盘运维脚本（FileProvider 方案版）
# 主用途: AList 状态、按需下载到本地、浏览
#
# 用法:
#   quark.sh status          状态
#   quark.sh browse          打开 AList Web UI（浏览全部网盘）
#   quark.sh sync <路径>     下载远程目录到本地（可选，本地留副本）
#   quark.sh pull <文件>     下载单个文件到本地
#   quark.sh free <路径>     释放本地副本（云端保留）
#   quark.sh logs            日志
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

LOCAL_ROOT="$HOME/QuarkDrive"        # 本地下载目录（可选使用）
ALIST_URL="http://localhost:5244"
LOG_DIR="$(cd "$(dirname "$0")/.." && pwd)/logs"
mkdir -p "$LOCAL_ROOT" "$LOG_DIR"

cmd="${1:-status}"

case "$cmd" in
  status)
    echo "── AList (夸克 WebDAV) ─────────────"
    curl -s -o /dev/null -w "  ✅ 运行中 http://localhost:5244\n" --max-time 5 "$ALIST_URL/" 2>/dev/null || echo "  ❌ 未运行"
    echo "── FileProvider 桥 (8081) ──────────"
    nc -z -w 2 127.0.0.1 8081 2>/dev/null && echo "  ✅ 运行中" || echo "  ❌ 未运行"
    echo "── FileProvider 盘 ─────────────────"
    ls -d "$HOME/Library/CloudStorage/"*Plinth* 2>/dev/null && echo "  ✅ Finder Locations 可见" || echo "  ⚠️  未注册（运行 app/Plinth.app）"
    ;;
  sync)
    target="${2:-}"
    if [ -z "$target" ]; then echo "用法: quark.sh sync <路径如 文档/阅读>"; exit 1; fi
    target=$(python3 -c "import sys,unicodedata; print(unicodedata.normalize('NFD', sys.argv[1]))" "$target")
    echo "[*] 下载 夸克:/$target → $LOCAL_ROOT/$target"
    rclone copy "quark:/$target" "$LOCAL_ROOT/$target" \
      --create-empty-src-dirs --transfers 8 --timeout 60s 2>&1 | tail -3 || true
    echo "[✓] 完成"
    ;;
  pull)
    target="${2:-}"
    if [ -z "$target" ]; then echo "用法: quark.sh pull <文件路径>"; exit 1; fi
    target=$(python3 -c "import sys,unicodedata; print(unicodedata.normalize('NFD', sys.argv[1]))" "$target")
    mkdir -p "$LOCAL_ROOT/$(dirname "$target")"
    rclone copy "quark:/$target" "$LOCAL_ROOT/$(dirname "$target")/" --timeout 60s 2>&1 | tail -2 || true
    echo "[✓] 已下载: $LOCAL_ROOT/$target"
    ;;
  free)
    target="${2:-}"
    if [ -z "$target" ]; then echo "用法: quark.sh free <相对路径>"; exit 1; fi
    target=$(python3 -c "import sys,unicodedata; print(unicodedata.normalize('NFD', sys.argv[1]))" "$target")
    rm -rf "$LOCAL_ROOT/$target" 2>/dev/null
    echo "[✓] 已释放 $target（云端保留）"
    ;;
  browse)
    open "$ALIST_URL"
    echo "[✓] 已打开 AList Web UI"
    ;;
  logs)
    echo "── fp-bridge ──"; tail -8 "$LOG_DIR/fp-bridge.log" 2>/dev/null || echo "(无)"
    echo "── alist ──"; tail -5 "$HOME/Library/Application Support/alist/server.log" 2>/dev/null || echo "(无)"
    ;;
  *)
    echo "用法: quark.sh {status|browse|sync <路径>|pull <文件>|free <路径>|logs}"
    ;;
esac

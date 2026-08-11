#!/usr/bin/env bash
# 配置夸克网盘存储（AList）
# Cookie 三种输入方式（按优先级）：
#   1. 文件: $DATA_DIR/quark-cookie.txt   （推荐，避免终端粘贴问题）
#   2. 环境变量: QUARK_COOKIE="..." ./setup-quark.sh
#   3. 交互粘贴（不推荐，某些终端粘贴长文本会出问题）
set -euo pipefail

ALIST_BIN="$HOME/.local/bin/alist"
ALIST_DATA="$HOME/Library/Application Support/alist"
ALIST_URL="http://localhost:5244"
MOUNT_PATH="/quark"
DATA_DIR="${FP_DATA_DIR:-$HOME/.cloud-drive-fp-data}"
PASS_FILE="$DATA_DIR/alist-admin-pass.txt"
COOKIE_FILE="$DATA_DIR/quark-cookie.txt"

echo "=== 夸克网盘存储配置 (AList) ==="

# --- 确保 AList 在运行 ---
if ! curl -s -o /dev/null "$ALIST_URL/"; then
  echo "[*] 启动 AList ..."
  cd "$ALIST_DATA"
  nohup "$ALIST_BIN" server > "$ALIST_DATA/server.log" 2>&1 &
  for i in $(seq 1 10); do curl -s -o /dev/null "$ALIST_URL/" && break; sleep 1; done
fi

# --- 读取管理员密码 ---
[[ -f "$PASS_FILE" ]] || { echo "[!] 缺少 $PASS_FILE"; exit 1; }
ADMIN_PASS=$(cat "$PASS_FILE")

# --- 登录拿 token ---
TOKEN=$(curl -s -X POST "$ALIST_URL/api/auth/login" -H "Content-Type: application/json" \
  -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASS\"}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['data']['token'])")
echo "[✓] AList 登录成功"

# --- 获取 cookie ---
if [[ -f "$COOKIE_FILE" && -s "$COOKIE_FILE" ]]; then
  COOKIE=$(tr -d '\r\n' < "$COOKIE_FILE")
  echo "[✓] 已从文件读取 cookie ($COOKIE_FILE, ${#COOKIE} 字符)"
elif [[ -n "${QUARK_COOKIE:-}" ]]; then
  COOKIE="$QUARK_COOKIE"
  echo "[✓] 已使用环境变量 QUARK_COOKIE"
else
  echo ""
  echo "⚠️  未找到 $COOKIE_FILE"
  echo "    请用下面任一方式提供夸克 Cookie："
  echo ""
  echo "  方式 1（推荐）: 在终端执行以下命令，粘贴后按 Ctrl-D 结束："
  echo "    cat > $DATA_DIR/quark-cookie.txt"
  echo ""
  echo "  方式 2: 在浏览器打开 https://pan.quark.cn 登录后，F12 → Network → 刷新 →"
  echo "          点任意请求 → 复制 Request Headers 里 Cookie 整行 → 存到上面的文件"
  echo ""
  echo "  获取后重新运行本脚本即可，无需再次输入。"
  exit 1
fi

if [[ ${#COOKIE} -lt 20 ]]; then
  echo "[!] Cookie 过短（${#COOKIE} 字符），请检查内容"; exit 1
fi

# --- 构造请求体（注意 addition 必须是 JSON 字符串） ---
ADDITION_JSON=$(python3 -c "
import json, sys
addition = {
    'cookie': sys.argv[1],
    'root_folder_id': '0',
    'order_by': 'none',
    'order_direction': 'asc',
    'use_transcoding_address': False,
    'only_list_video_file': False,
    'down_concurrency': 32,
    'down_part_size': 10
}
print(json.dumps(addition))
" "$COOKIE")

BODY=$(python3 -c "
import json, sys
print(json.dumps({
    'driver': 'Quark',
    'mount_path': '$MOUNT_PATH',
    'addition': json.loads(sys.argv[1]),
    'remark': 'quark'
}))
" "$ADDITION_JSON")

# --- 检查是否已存在 ---
EXIST=$(curl -s "$ALIST_URL/api/admin/storage/list" -H "Authorization: $TOKEN" \
  | python3 -c "
import json,sys
for s in json.load(sys.stdin)['data']['content']:
    if s['mount_path'] == '$MOUNT_PATH':
        print(s['id']); break
" || true)

if [[ -n "$EXIST" ]]; then
  echo "[*] 更新已有存储 #$EXIST ..."
  BODY=$(python3 -c "
import json, sys
print(json.dumps({
    'id': int(sys.argv[1]),
    'driver': 'Quark',
    'mount_path': '$MOUNT_PATH',
    'webdav_policy': 'native_proxy',
    'addition': sys.argv[2],
    'remark': 'quark'
}))
" "$EXIST" "$ADDITION_JSON")
  curl -s -X POST "$ALIST_URL/api/admin/storage/update" -H "Authorization: $TOKEN" \
    -H "Content-Type: application/json" -d "$BODY" | python3 -c "import json,sys; d=json.load(sys.stdin); print('[✓]' if d['code']==200 else '[!] '+str(d))"
else
  echo "[*] 新建存储 $MOUNT_PATH ..."
  BODY=$(python3 -c "
import json, sys
print(json.dumps({
    'driver': 'Quark',
    'mount_path': '$MOUNT_PATH',
    'webdav_policy': 'native_proxy',
    'addition': sys.argv[1],
    'remark': 'quark'
}))
" "$ADDITION_JSON")
  curl -s -X POST "$ALIST_URL/api/admin/storage/create" -H "Authorization: $TOKEN" \
    -H "Content-Type: application/json" -d "$BODY" | python3 -c "import json,sys; d=json.load(sys.stdin); print('[✓]' if d['code']==200 else '[!] '+str(d))"
fi

# --- 等待 AList 初始化夸克驱动，检查状态 ---
echo "[*] 等待 AList 初始化夸克驱动 (最多 15s) ..."
for i in $(seq 1 15); do
  sleep 1
  ST=$(curl -s "$ALIST_URL/api/admin/storage/list" -H "Authorization: $TOKEN" \
    | python3 -c "
import json,sys
for s in json.load(sys.stdin)['data']['content']:
    if s['mount_path'] == '$MOUNT_PATH':
        st = s.get('status','')
        print(st); break
" 2>/dev/null)
  [[ -n "$ST" ]] && break
done
echo "    存储状态: ${ST:-未知}"

# --- 验证 WebDAV 链路 ---
echo ""
echo "[*] 验证: rclone lsd quark:/quark"
sleep 2
if OUT=$(rclone lsd quark:/quark 2>&1); then
  echo "$OUT" | head -20
  echo ""
  echo "✅ 配置成功！夸克网盘已挂载到 AList 路径 $MOUNT_PATH"
  echo "   下一步挂载到本地: ./quark.sh mount   （需 sudo 密码）"
else
  echo "⚠️  rclone 列目录失败:"
  echo "$OUT" | tail -3
  echo ""
  echo "可能原因:"
  echo "  1. cookie 无效/已过期 → 重新获取后再次运行本脚本"
  echo "  2. 存储未启用 → 打开 http://localhost:5244 检查"
  echo "  3. 需要等待初始化完成 → 10 秒后重试: rclone lsd quark:/quark"
fi

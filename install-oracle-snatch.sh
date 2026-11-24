#!/usr/bin/env bash
#
# oracle-snatch 一键部署脚本（交互式）
# 在一台已有的 Ubuntu/Debian 机器上部署 oracle-snatch，
# 自动重试创建 Oracle Always Free 的 VM.Standard.A1.Flex 实例。
#
# 用法（root 身份）：
#   bash install-oracle-snatch.sh
# 或从 GitHub 拉取运行（脚本提问走 /dev/tty，管道运行也能交互）：
#   curl -sL -o install-oracle-snatch.sh https://raw.githubusercontent.com/<仓库>/main/install-oracle-snatch.sh
#   bash install-oracle-snatch.sh
#
# 需要你输入的只有：区域、API 凭据、子网 OCID，以及可选的 Telegram token / chat id。
# 脚本本身不含任何密钥，输入只写进本机 /root 下的配置文件。

SNATCH_URL="https://raw.githubusercontent.com/lucasforster1108-boop/oracle-snatch/main/snatch.py"
SNATCH_MD5="255234e40d2308024d7c320fd6464dc4"
BASE="/root"
VENV="/root/snatch-venv"
OCI_DIR="/root/.oci"

say()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
info() { printf '%s\n' "$*"; }
die()  { printf '\n[出错] %s\n' "$*" >&2; exit 1; }

# ask "问题" "默认值" -> 结果在 $REPLY_A
ask() {
  local q="$1" def="${2:-}" ans=""
  if [ -n "$def" ]; then
    printf '%s [%s]: ' "$q" "$def" > /dev/tty
  else
    printf '%s: ' "$q" > /dev/tty
  fi
  IFS= read -r ans < /dev/tty || ans=""
  REPLY_A="${ans:-$def}"
}

[ "$(id -u)" = "0" ] || die "请先 sudo -i 切到 root 再运行本脚本。"

say "1/8 选择区域（A1 只能建在租户的 home region）"
info "  1) ap-tokyo-1（东京）"
info "  2) ap-singapore-1（新加坡）"
info "  3) 手动输入"
ask "输入序号" "1"
case "$REPLY_A" in
  2) REGION="ap-singapore-1"; SHORT="sg" ;;
  3) ask "区域名（如 ap-osaka-1）" ""; REGION="$REPLY_A"
     ask "实例名前缀短名（如 osaka）" "a1"; SHORT="$REPLY_A" ;;
  *) REGION="ap-tokyo-1"; SHORT="tokyo" ;;
esac
[ -n "$REGION" ] || die "区域不能为空。"

say "2/8 实例参数"
ask "抢几台（免费额度现行合计 2 核 / 12 GB，请量力）" "2"
case "$REPLY_A" in 1|2|3|4) COUNT="$REPLY_A" ;; *) COUNT=2 ;; esac
ask "每台 OCPU 数" "1"; OCPUS="$REPLY_A"
ask "每台内存 GB" "6"; MEMORY="$REPLY_A"
ask "每台启动盘 GB（A1 最小 50）" "50"; BOOT="$REPLY_A"
[ "$BOOT" -ge 50 ] 2>/dev/null || BOOT=50
ask "实例名前缀" "a1-$SHORT"; PREFIX="$REPLY_A"

say "3/8 API 凭据"
mkdir -p "$OCI_DIR"
KEY_FILE="$OCI_DIR/oci_api_key.pem"
REUSE=0
if [ -f "$OCI_DIR/config" ] && [ -f "$KEY_FILE" ]; then
  ask "检测到已有 /root/.oci/config 和私钥，复用它们？(y/n)" "y"
  case "$REPLY_A" in y|Y) REUSE=1 ;; esac
fi
if [ "$REUSE" != "1" ]; then
  info "  1) 在本机生成密钥对（推荐：私钥不出本机，只把公钥粘到控制台）"
  info "  2) 粘贴控制台生成的私钥（你在控制台下载的 .pem）"
  ask "输入序号" "1"
  if [ "$REPLY_A" = "2" ]; then
    info "把私钥全文粘贴进来，粘完后单独一行输入 EOF 再回车："
    : > "$KEY_FILE"
    while IFS= read -r line < /dev/tty; do
      [ "$line" = "EOF" ] && break
      printf '%s\n' "$line" >> "$KEY_FILE"
    done
    sed -i 's/\r$//' "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    openssl rsa -in "$KEY_FILE" -check -noout 2>/dev/null | grep -q "RSA key ok" \
      || die "私钥校验没通过，可能粘贴不完整，重新运行脚本再试。"
    ask "user OCID（控制台添加密钥后的预览里有）" ""; USER_OCID="$REPLY_A"
    ask "fingerprint（预览里有）" ""; FINGERPRINT="$REPLY_A"
    ask "tenancy OCID（预览里有）" ""; TENANCY_OCID="$REPLY_A"
  else
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$KEY_FILE" 2>/dev/null \
      || die "生成密钥对失败。"
    chmod 600 "$KEY_FILE"
    FINGERPRINT="$(openssl rsa -in "$KEY_FILE" -pubout -outform DER 2>/dev/null | openssl md5 -c | awk '{print $2}')"
    info ""
    info "已在本机生成密钥对。下面这段是公钥，整段复制下来，"
    info "去控制台：用户设置 → API 密钥 → 添加 API 密钥 → 粘贴公钥 → 添加。"
    info "----- 公钥开始 -----"
    openssl rsa -in "$KEY_FILE" -pubout 2>/dev/null
    info "----- 公钥结束 -----"
    ask "添加完成后，输入控制台显示的 user OCID" ""; USER_OCID="$REPLY_A"
    ask "输入控制台显示的 tenancy OCID" ""; TENANCY_OCID="$REPLY_A"
    info "fingerprint 已由脚本自动算出：$FINGERPRINT"
  fi
  [ -n "$USER_OCID" ] && [ -n "$TENANCY_OCID" ] && [ -n "$FINGERPRINT" ] \
    || die "user / tenancy / fingerprint 有空缺，重新运行脚本再填。"
  cat > "$OCI_DIR/config" <<EOF
[DEFAULT]
user=$USER_OCID
fingerprint=$FINGERPRINT
tenancy=$TENANCY_OCID
region=$REGION
key_file=$KEY_FILE
EOF
  chmod 600 "$OCI_DIR/config"
fi

say "4/8 子网"
info "在控制台打开任意一台同区域的现有实例 → 点它的子网 → 复制 OCID（ocid1.subnet.oc1.. 开头）。"
ask "子网 OCID" ""; SUBNET_ID="$REPLY_A"
case "$SUBNET_ID" in ocid1.subnet.oc1.*) ;; *) die "子网 OCID 格式不对，应是 ocid1.subnet.oc1.. 开头。" ;; esac

say "5/8 Telegram 通知（可跳过）"
ask "TG_BOT_TOKEN（直接回车跳过）" ""; TG_TOKEN="$REPLY_A"
TG_CHAT=""
if [ -n "$TG_TOKEN" ]; then ask "TG_CHAT_ID" ""; TG_CHAT="$REPLY_A"; fi

say "6/8 安装运行环境"
if ! python3 -m venv --help >/dev/null 2>&1; then
  apt-get update && apt-get install -y python3-venv || die "apt 安装 python3-venv 失败。"
fi
[ -x "$VENV/bin/python" ] || python3 -m venv "$VENV" || die "创建 venv 失败。"
"$VENV/bin/pip" install -q -U pip oci || die "pip 安装 oci SDK 失败。"
"$VENV/bin/python" -c "import oci" || die "oci SDK 校验失败。"
info "oci SDK 版本：$("$VENV/bin/python" -c 'import oci; print(oci.__version__)')"
mkdir -p /root/.ssh
if [ ! -f /root/.ssh/a1_key ]; then
  ssh-keygen -t ed25519 -f /root/.ssh/a1_key -N '' >/dev/null
  info "已生成新机登录密钥 /root/.ssh/a1_key（抢到机器后拷一份回自己电脑）。"
fi

say "7/8 写配置与服务"
TMP_SNATCH="$(mktemp)"
curl -sL -o "$TMP_SNATCH" "$SNATCH_URL" || die "下载 snatch.py 失败。"
echo "$SNATCH_MD5  $TMP_SNATCH" | md5sum -c - >/dev/null 2>&1 \
  || die "snatch.py 的 md5 与审过的版本不一致，已中止。实际 md5：$(md5sum "$TMP_SNATCH" | awk '{print $1}')"

i=1
while [ "$i" -le "$COUNT" ]; do
  DIR="$BASE/oracle-snatch-$i"
  mkdir -p "$DIR"
  cp "$TMP_SNATCH" "$DIR/snatch.py"
  cat > "$DIR/config.env" <<EOF
SUBNET_ID=$SUBNET_ID
DISPLAY_NAME=$PREFIX-$i
OCPUS=$OCPUS
MEMORY_GB=$MEMORY
BOOT_VOLUME_GB=$BOOT
INTERVAL_SECONDS=120
RATE_LIMIT_SLEEP_SECONDS=300
SSH_PUBLIC_KEY_FILE=/root/.ssh/a1_key.pub
OCI_CONFIG_FILE=$OCI_DIR/config
OCI_PROFILE=DEFAULT
TG_BOT_TOKEN=$TG_TOKEN
TG_CHAT_ID=$TG_CHAT
EOF
  cat > "$BASE/oracle-snatch-$i.service" <<EOF
[Unit]
Description=oracle-snatch A1 $PREFIX-$i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=$DIR
ExecStart=$VENV/bin/python $DIR/snatch.py --config $DIR/config.env
Restart=on-failure
RestartSec=60

[Install]
WantedBy=multi-user.target
EOF
  i=$((i + 1))
done
rm -f "$TMP_SNATCH"

say "8/8 验证并启动"
cd "$BASE/oracle-snatch-1" || die "目录不存在。"
if ! "$VENV/bin/python" snatch.py --config config.env --dry-run; then
  die "dry-run 没通过，服务未启动。把上面的报错原文发给维护者看。"
fi
ask "dry-run 通过，立即开始抢第一台？(y/n)" "y"
case "$REPLY_A" in
  y|Y)
    cp "$BASE/oracle-snatch-1.service" /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now oracle-snatch-1 || die "启动服务失败。"
    sleep 3
    journalctl -u oracle-snatch-1 -n 10 --no-pager || true
    ;;
  *) info "已跳过启动。想开始时运行：systemctl enable --now oracle-snatch-1（先 cp 服务文件，见下方说明）" ;;
esac

if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT" ]; then
  if curl -s "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
       --data-urlencode "chat_id=${TG_CHAT}" \
       --data-urlencode "text=oracle-snatch 部署完成（$REGION），开始抢 $PREFIX-1" | grep -q '"ok":true'; then
    info "Telegram 测试通知已发出。"
  else
    info "Telegram 测试通知没发成功（不影响抢机），请检查 token / chat id。"
  fi
fi

say "完成"
info "查进度：  systemctl is-active oracle-snatch-1"
info "看日志：  journalctl -u oracle-snatch-1 -n 5 --no-pager"
info "抢到没：  cat /root/oracle-snatch-1/snatched.json（出现 IP 就是到手）"
if [ "$COUNT" -ge 2 ]; then
  info "第一台到手后开第二台："
  info "  cp /root/oracle-snatch-2.service /etc/systemd/system/ && systemctl daemon-reload && systemctl enable --now oracle-snatch-2"
fi
info "提醒：A1 免费机闲置 7 天会被 Oracle 回收，抢到后尽快部署使用；"
info "登录新机用 /root/.ssh/a1_key（用户 ubuntu），记得把私钥拷回自己电脑。"

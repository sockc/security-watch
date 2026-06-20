#!/usr/bin/env bash
set -u

APP_NAME="Security Watch"
APP_DIR="/opt/security-watch"
CONF_DIR="/etc/security-watch"
LOG_DIR="/var/log/security-watch"
BIN="/usr/local/bin/security-watch"
CONF="$CONF_DIR/config.env"
SERVICE_FILE="/etc/systemd/system/security-watch.service"
TIMER_FILE="/etc/systemd/system/security-watch.timer"

BAD='xmrig|c3pool|stratum|monero|cryptonight|kinsing|kdevtmpfsi|SystemLoger'
NEZHA='nezha-agent|nezha-dashboard|/opt/nezha|/tmp/nezha|nezha'
EXCLUDE='grep|security-watch|virus-return-check|nezha-cleaner'

TG_BOT_TOKEN=""
TG_CHAT_ID=""
TG_THREAD_ID=""
HOST_ALIAS="$(hostname)"
DAILY_TIME="03:30"

load_config() {
  [ -f "$CONF" ] && source "$CONF"
  HOST_ALIAS="${HOST_ALIAS:-$(hostname)}"
  DAILY_TIME="${DAILY_TIME:-03:30}"
}

save_config() {
  mkdir -p "$CONF_DIR"
  {
    printf "TG_BOT_TOKEN=%q\n" "${TG_BOT_TOKEN:-}"
    printf "TG_CHAT_ID=%q\n" "${TG_CHAT_ID:-}"
    printf "TG_THREAD_ID=%q\n" "${TG_THREAD_ID:-}"
    printf "HOST_ALIAS=%q\n" "${HOST_ALIAS:-$(hostname)}"
    printf "DAILY_TIME=%q\n" "${DAILY_TIME:-03:30}"
  } > "$CONF"
  chmod 600 "$CONF"
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 运行：sudo -i 后再执行"
    exit 1
  fi
}

pause() {
  echo
  read -rp "按回车继续..." _
}

ask() {
  local prompt="$1"
  local default="$2"
  local value
  if [ -n "$default" ]; then
    read -rp "$prompt [$default]: " value
    echo "${value:-$default}"
  else
    read -rp "$prompt: " value
    echo "$value"
  fi
}

send_tg() {
  local text="$1"

  load_config

  if [ -z "${TG_BOT_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ]; then
    echo "[WARN] Telegram 未配置，跳过推送"
    return 0
  fi

  if [ -n "${TG_THREAD_ID:-}" ]; then
    curl -sS -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TG_CHAT_ID}" \
      -d "message_thread_id=${TG_THREAD_ID}" \
      -d "text=${text}" \
      -d "disable_web_page_preview=true" >/dev/null || true
  else
    curl -sS -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
      -d "chat_id=${TG_CHAT_ID}" \
      -d "text=${text}" \
      -d "disable_web_page_preview=true" >/dev/null || true
  fi
}

configure() {
  need_root
  load_config

  echo
  echo "========== Telegram 配置 =========="
  echo

  TG_BOT_TOKEN="$(ask 'Telegram Bot Token' "${TG_BOT_TOKEN:-}")"
  TG_CHAT_ID="$(ask 'Telegram Chat ID' "${TG_CHAT_ID:-}")"
  TG_THREAD_ID="$(ask 'Telegram Topic Thread ID，可空' "${TG_THREAD_ID:-}")"
  HOST_ALIAS="$(ask '服务器显示名称' "${HOST_ALIAS:-$(hostname)}")"
  DAILY_TIME="$(ask '每日检测时间，例如 03:30' "${DAILY_TIME:-03:30}")"

  save_config

  echo
  echo "配置已保存：$CONF"
}

install_watch() {
  need_root

  mkdir -p "$APP_DIR" "$CONF_DIR" "$LOG_DIR"

  local self
  self="$(readlink -f "$0")"

RAW_URL="https://raw.githubusercontent.com/sockc/security-watch/main/security-watch.sh"

if [ -f "$0" ]; then
  cp "$0" "$APP_DIR/security-watch.sh" 2>/dev/null || true
fi

if [ ! -s "$APP_DIR/security-watch.sh" ]; then
  curl -fsSL "$RAW_URL" -o "$APP_DIR/security-watch.sh"
fi

chmod +x "$APP_DIR/security-watch.sh"
ln -sf "$APP_DIR/security-watch.sh" "$BIN"
chmod +x "$BIN" 2>/dev/null || true

  if [ ! -f "$CONF" ]; then
    configure
  else
    load_config
  fi

  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Security Watch Daily Scanner
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$CONF
ExecStart=$BIN scan
EOF

  cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Run Security Watch Daily

[Timer]
OnCalendar=*-*-* ${DAILY_TIME}:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now security-watch.timer

  echo
  echo "安装完成。"
  echo
  systemctl list-timers | grep security-watch || true

  send_tg "✅ Security Watch 已安装
主机: ${HOST_ALIAS}
每日检测时间: ${DAILY_TIME}
时间: $(date '+%F %T %Z')"
}

reinstall_timer() {
  need_root
  load_config

  cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Run Security Watch Daily

[Timer]
OnCalendar=*-*-* ${DAILY_TIME}:00
Persistent=true
RandomizedDelaySec=300

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now security-watch.timer
  systemctl restart security-watch.timer

  echo "定时器已更新为每日 ${DAILY_TIME}"
}

status_watch() {
  echo
  echo "========== 服务状态 =========="
  systemctl status security-watch.timer --no-pager 2>/dev/null || true

  echo
  echo "========== 下次运行 =========="
  systemctl list-timers | grep security-watch || true

  echo
  echo "========== 配置 =========="
  if [ -f "$CONF" ]; then
    sed -E 's/(TG_BOT_TOKEN=).*/\1***MASKED***/' "$CONF"
  else
    echo "未配置"
  fi
}

show_logs() {
  echo
  echo "========== 最近报告 =========="
  ls -lah "$LOG_DIR" 2>/dev/null | tail -n 20 || echo "暂无日志"

  local latest
  latest="$(ls -1t "$LOG_DIR"/security-watch-*.log 2>/dev/null | head -n 1 || true)"

  if [ -n "$latest" ]; then
    echo
    echo "========== 最新报告：$latest =========="
    tail -n 120 "$latest"
  fi
}

test_tg() {
  load_config

  send_tg "✅ Telegram 推送测试成功
主机: ${HOST_ALIAS}
时间: $(date '+%F %T %Z')"

  echo "测试消息已发送。如果没收到，请检查 Bot Token / Chat ID。"
}

cleanup_reports() {
  need_root
  mkdir -p "$LOG_DIR"
  find "$LOG_DIR" -name "security-watch-*.log" -type f -mtime +14 -delete 2>/dev/null || true
  echo "已清理 14 天前的报告。"
}

uninstall_watch() {
  need_root

  echo
  read -rp "确认卸载 Security Watch？输入 yes 继续: " ok
  [ "$ok" = "yes" ] || {
    echo "已取消"
    exit 0
  }

  systemctl disable --now security-watch.timer 2>/dev/null || true
  systemctl stop security-watch.service 2>/dev/null || true

  rm -f "$SERVICE_FILE" "$TIMER_FILE"
  rm -f "$BIN"
  rm -rf "$APP_DIR"

  systemctl daemon-reload
  systemctl reset-failed

  echo "已卸载程序。配置仍保留：$CONF"
  echo "日志仍保留：$LOG_DIR"
}

scan_watch() {
  need_root
  load_config

  mkdir -p "$LOG_DIR"

  local REPORT
  REPORT="$LOG_DIR/security-watch-$(date +%Y%m%d-%H%M%S).log"

  local ALERT=0
  local WARN=0
  local CLEAN=0
  local ALERT_TEXT=""
  local WARN_TEXT=""
  local CLEAN_TEXT=""

  add_alert() {
    ALERT=$((ALERT + 1))
    ALERT_TEXT="${ALERT_TEXT}
❌ $1"
  }

  add_warn() {
    WARN=$((WARN + 1))
    WARN_TEXT="${WARN_TEXT}
⚠️ $1"
  }
    add_clean() {
    CLEAN=$((CLEAN + 1))
    CLEAN_TEXT="${CLEAN_TEXT}
🧹 $1"
  }

  delete_level1_path() {
    local p="$1"

    case "$p" in
      /root/c3pool|/root/c3pool/*|\
/opt/c3pool|/opt/c3pool/*|\
/tmp/c3pool|/tmp/c3pool/*|\
/var/tmp/c3pool|/var/tmp/c3pool/*|\
/dev/shm/c3pool|/dev/shm/c3pool/*|\
/tmp/xmrig|/var/tmp/xmrig|/dev/shm/xmrig|\
/etc/systemd/system/c3pool_miner.service|\
/etc/systemd/system/multi-user.target.wants/c3pool_miner.service|\
/tmp/c3pool_miner.service)
        ;;
      *)
        echo "[SKIP] 非白名单明确恶意路径，不自动删除: $p"
        return 0
        ;;
    esac

    if [ -e "$p" ] || [ -L "$p" ]; then
      if [ -d "$p" ] && [ ! -L "$p" ]; then
        rm -rf -- "$p"
      else
        rm -f -- "$p"
      fi
      echo "[AUTO-CLEAN] 已删除: $p"
      add_clean "已删除: $p"
    fi
  }  

  section() {
    echo
    echo "========== $1 =========="
  }

  exec > >(tee -a "$REPORT") 2>&1

  section "基本信息"
  echo "时间: $(date -u)"
  echo "主机: $(hostname)"
  echo "别名: ${HOST_ALIAS}"
  echo "系统: $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')"
  echo "运行时间: $(uptime -p 2>/dev/null || uptime)"
  echo "报告文件: $REPORT"

  section "1. 进程扫描"
  OUT="$(ps auxww | grep -Ei "$BAD|$NEZHA" | grep -Ev "$EXCLUDE" || true)"
  if [ -n "$OUT" ]; then
    echo "[ALERT] 发现可疑进程:"
    echo "$OUT"
    add_alert "发现可疑进程"
  else
    echo "[OK] 未发现哪吒/矿机进程"
  fi

  section "2. systemd 服务扫描"
  OUT1="$(systemctl list-units --all 2>/dev/null | grep -Ei "$BAD|$NEZHA" | grep -Ev "$EXCLUDE" || true)"
  OUT2="$(systemctl list-unit-files 2>/dev/null | grep -Ei "$BAD|$NEZHA" | grep -Ev "$EXCLUDE" || true)"

  if [ -n "$OUT1$OUT2" ]; then
    echo "[ALERT] 发现可疑 systemd 服务:"
    echo "$OUT1"
    echo "$OUT2"
    add_alert "发现可疑 systemd 服务"
  else
    echo "[OK] 未发现哪吒/矿机 systemd 服务"
  fi

  section "3A. 明确恶意文件扫描"

LEVEL1_FILES="$(find /root /opt /tmp /var/tmp /dev/shm /etc/systemd/system \
  -maxdepth 5 \( \
  -path '*/c3pool' -o \
  -path '*/c3pool/*' -o \
  -iname 'xmrig' -o \
  -iname 'c3pool_miner.service' -o \
  -iname '*c3pool*' \
  \) 2>/dev/null \
  | grep -Ev 'security-watch-quarantine|security-watch|virus-return-check|nezha-cleaner' || true)"

if [ -n "$LEVEL1_FILES" ]; then
  echo "[ALERT] 发现明确恶意挖矿文件:"
  echo "$LEVEL1_FILES"
  add_alert "发现明确恶意挖矿文件"
else
  echo "[OK] 未发现明确恶意挖矿文件"
fi

    section "3A. 明确恶意挖矿文件扫描与自动清理"

  LEVEL1_FILES="$(find /root /opt /tmp /var/tmp /dev/shm /etc/systemd/system \
    -maxdepth 6 \( \
    -path '/root/c3pool' -o \
    -path '/root/c3pool/*' -o \
    -path '/opt/c3pool' -o \
    -path '/opt/c3pool/*' -o \
    -path '/tmp/c3pool' -o \
    -path '/tmp/c3pool/*' -o \
    -path '/var/tmp/c3pool' -o \
    -path '/var/tmp/c3pool/*' -o \
    -path '/dev/shm/c3pool' -o \
    -path '/dev/shm/c3pool/*' -o \
    -path '/etc/systemd/system/c3pool_miner.service' -o \
    -path '/etc/systemd/system/multi-user.target.wants/c3pool_miner.service' -o \
    -path '/tmp/c3pool_miner.service' -o \
    -path '/tmp/xmrig' -o \
    -path '/var/tmp/xmrig' -o \
    -path '/dev/shm/xmrig' \
    \) 2>/dev/null \
    | grep -Ev 'security-watch-quarantine|security-watch|virus-return-check|nezha-cleaner' || true)"

  if [ -n "$LEVEL1_FILES" ]; then
    echo "[ALERT] 发现明确恶意挖矿文件:"
    echo "$LEVEL1_FILES"
    add_alert "发现明确恶意挖矿文件"

    echo
    echo "[AUTO-CLEAN] 开始自动清理明确恶意项"

    systemctl stop c3pool_miner.service 2>/dev/null || true
    systemctl disable c3pool_miner.service 2>/dev/null || true
    systemctl mask c3pool_miner.service 2>/dev/null || true

    pkill -9 -f xmrig 2>/dev/null || true
    pkill -9 -f c3pool 2>/dev/null || true
    pkill -9 -f stratum 2>/dev/null || true
    pkill -9 -f monero 2>/dev/null || true

    echo "$LEVEL1_FILES" | sort -r | while IFS= read -r p; do
      [ -n "$p" ] || continue
      delete_level1_path "$p"
    done

    systemctl daemon-reload
    systemctl reset-failed

    echo "[AUTO-CLEAN] 明确恶意项清理完成"
  else
    echo "[OK] 未发现明确恶意挖矿文件"
  fi

  section "3. 文件残留扫描"
  OUT="$(find /opt /tmp /var/tmp /dev/shm /etc/systemd/system /root /home \
    -maxdepth 5 \( \
    -iname '*nezha*' -o \
    -iname '*xmrig*' -o \
    -iname '*c3pool*' -o \
    -iname '*miner*' -o \
    -iname '*monero*' -o \
    -iname '*xmr*' -o \
    -iname '*SystemLoger*' -o \
    -iname '*kinsing*' -o \
    -iname '*kdevtmpfsi*' \
    \) 2>/dev/null \
        | grep -Ev 'security-watch|virus-return-check|nezha-cleaner|ir/nezha-agent-passwd|security-watch-|security-watch-quarantine|/root/ir-nezha|/root/c3pool' || true)"

  if [ -n "$OUT" ]; then
    echo "[WARN] 发现可疑文件/目录残留:"
    echo "$OUT"
    add_warn "发现可疑文件/目录残留"
  else
    echo "[OK] 未发现明显文件残留"
  fi

  section "4. cron / systemd 持久化扫描"
  OUT="$(grep -RniEi "$BAD|chpasswd|passwd root|/opt/nezha|/tmp/nezha|nezha-agent|curl .*\|.*sh|wget .*\|.*sh|base64 -d" \
    /etc/crontab /etc/cron* /var/spool/cron* /etc/systemd/system 2>/dev/null \
    | grep -Ev 'open-vm-tools|RequiresMountsFor=/tmp|security-watch|virus-return-check|nezha-cleaner' || true)"

  if [ -n "$OUT" ]; then
    echo "[ALERT] 发现可疑 cron/systemd 持久化:"
    echo "$OUT"
    add_alert "发现可疑 cron/systemd 持久化"
  else
    echo "[OK] cron/systemd 未发现可疑持久化"
  fi

  section "5. 所有用户 crontab"
  FOUND_CRON=0

  for u in $(cut -d: -f1 /etc/passwd); do
    CT="$(crontab -u "$u" -l 2>/dev/null | grep -Ei "$BAD|chpasswd|passwd root|nezha|base64|/dev/shm" || true)"
    if [ -n "$CT" ]; then
      echo "[WARN] 用户 $u 的 crontab 需要确认:"
      echo "$CT"
      FOUND_CRON=1
    fi
  done

  if [ "$FOUND_CRON" -eq 0 ]; then
    echo "[OK] 用户 crontab 未发现明显可疑内容"
  else
    add_warn "用户 crontab 有可疑内容"
  fi

  section "6. 最近 3 天关键日志"
  OUT="$(journalctl --since '3 days ago' -o short-iso 2>/dev/null \
    | grep -Ei "$BAD|chpasswd|password changed for root|Accepted .* for root|nezha-agent|c3pool_miner" \
    | grep -Ev 'security-watch|virus-return-check|nezha-cleaner' || true)"

  if [ -n "$OUT" ]; then
    echo "[ALERT] 最近 3 天发现关键异常日志:"
    echo "$OUT"
    add_alert "最近 3 天发现 root 改密/矿机/哪吒日志"
  else
    echo "[OK] 最近 3 天未发现 root 改密/矿机/哪吒关键日志"
  fi

  section "7. 网络连接扫描"
  OUT="$(ss -tunp 2>/dev/null \
    | grep -Ei "$BAD|stratum|:3333|:4444|:5555|:7777|:14444|:19999|:33333|:55555" \
    | grep -Ev "$EXCLUDE" || true)"

  if [ -n "$OUT" ]; then
    echo "[ALERT] 发现疑似矿池/可疑网络连接:"
    echo "$OUT"
    add_alert "发现疑似矿池/可疑网络连接"
  else
    echo "[OK] 未发现明显矿池连接"
  fi

  section "8. SSH 加固状态"
  SSH_STATUS="$(sshd -T 2>/dev/null | grep -Ei 'permitrootlogin|passwordauthentication|kbdinteractiveauthentication|challengeresponseauthentication|pubkeyauthentication|usepam' || true)"
  echo "$SSH_STATUS"

  ROOT_STATUS="$(passwd -S root 2>/dev/null || true)"
  echo "$ROOT_STATUS"

  echo "$SSH_STATUS" | grep -qi "permitrootlogin no" || add_warn "SSH PermitRootLogin 不是 no"
  echo "$SSH_STATUS" | grep -qi "passwordauthentication no" || add_warn "SSH PasswordAuthentication 不是 no"
  echo "$SSH_STATUS" | grep -qi "kbdinteractiveauthentication no" || add_warn "SSH KbdInteractiveAuthentication 不是 no"
  echo "$ROOT_STATUS" | grep -qE '^root L|^root LK' || add_warn "root 密码未锁定"

  section "9. authorized_keys 审计"
  find /root /home -name authorized_keys -type f 2>/dev/null | while read -r f; do
    echo "----- $f -----"
    nl -ba "$f" | sed -E 's/(ssh-rsa|ssh-ed25519|ecdsa-sha2-[^ ]+) [A-Za-z0-9+\/=]+/\1 KEY_MASKED/g'
  done

  section "10. 最近 3 天新增/修改敏感文件"
  OUT="$(find /etc/systemd/system /etc/cron.d /etc/cron.daily /etc/cron.hourly /var/spool/cron /opt /tmp /var/tmp /dev/shm \
    -type f -mtime -3 -ls 2>/dev/null \
    | grep -Ev 'security-watch|virus-return-check|nezha-cleaner|1panel/log|1Panel.db|monitor.db|beszel_health|lucky.control.token' || true)"

  if [ -n "$OUT" ]; then
    echo "[WARN] 最近 3 天敏感路径有新增/修改文件:"
    echo "$OUT"
    add_warn "最近 3 天敏感路径有新增/修改文件"
  else
    echo "[OK] 未发现最近 3 天敏感路径异常新增文件"
  fi

  section "11. Docker 容器矿机扫描"
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo "当前容器:"
    docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}"

    DOCKER_HIT=0
    for c in $(docker ps -q); do
      NAME="$(docker inspect -f '{{.Name}} {{.Config.Image}}' "$c" 2>/dev/null)"
      TOP="$(docker top "$c" 2>/dev/null | grep -Ei "$BAD" || true)"
      CMD="$(docker inspect -f '{{json .Config.Cmd}} {{json .Config.Entrypoint}}' "$c" 2>/dev/null | grep -Ei "$BAD|stratum|monero|xmr" || true)"

      if [ -n "$TOP$CMD" ]; then
        echo "[ALERT] 容器可疑: $c $NAME"
        echo "$TOP"
        echo "$CMD"
        DOCKER_HIT=1
      fi
    done

    if [ "$DOCKER_HIT" -eq 0 ]; then
      echo "[OK] Docker 容器内未发现矿机关键词"
    else
      add_alert "Docker 容器内发现矿机关键词"
    fi
  else
    echo "[OK] Docker 未安装或未运行"
  fi

  section "12. 总结"
  echo "ALERT 数量: $ALERT"
  echo "WARN  数量: $WARN"
  echo "CLEAN 数量: $CLEAN"

  if [ "$ALERT" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    RESULT="✅ 干净：未发现复发迹象"
  elif [ "$ALERT" -eq 0 ]; then
    RESULT="⚠️ 暂未发现复发，但有 ${WARN} 个需要确认项目"
  else
    if [ "$CLEAN" -gt 0 ]; then
      RESULT="🚨 发现明确恶意项并已自动清理：ALERT=${ALERT}, CLEAN=${CLEAN}, WARN=${WARN}"
    else
      RESULT="🚨 可能复发或仍有后门：ALERT=${ALERT}, WARN=${WARN}"
    fi
  fi

  echo "$RESULT"
  echo "报告文件: $REPORT"

  MSG="${RESULT}
主机: ${HOST_ALIAS}
时间: $(date '+%F %T %Z')
ALERT: ${ALERT}
WARN: ${WARN}
CLEAN: ${CLEAN}
${ALERT_TEXT}
${WARN_TEXT}
${CLEAN_TEXT}

报告文件: ${REPORT}"

  send_tg "$MSG"

  if [ "$ALERT" -gt 0 ]; then
    exit 2
  elif [ "$WARN" -gt 0 ]; then
    exit 1
  else
    exit 0
  fi
}

update_self() {
  need_root

  if [ -d "/root/server-virus-watch/.git" ]; then
    cd /root/server-virus-watch
    git pull
    cp security-watch.sh "$APP_DIR/security-watch.sh"
    chmod +x "$APP_DIR/security-watch.sh"
    echo "已从 /root/server-virus-watch 更新。"
  else
    echo "未发现 /root/server-virus-watch/.git"
    echo "如果是 curl 安装，请重新执行远程安装命令。"
  fi
}

menu() {
  while true; do
    clear
    echo "======================================"
    echo "        Security Watch 管理菜单"
    echo "======================================"
    echo " 1. 安装 / 更新到系统"
    echo " 2. 配置 Telegram / 主机名 / 检测时间"
    echo " 3. 立即检测一次"
    echo " 4. 查看定时器和服务状态"
    echo " 5. 查看最近报告"
    echo " 6. 发送 Telegram 测试消息"
    echo " 7. 重新生成定时器"
    echo " 8. 清理 14 天前报告"
    echo " 9. 从 GitHub 更新脚本"
    echo "10. 卸载"
    echo " 0. 退出"
    echo "======================================"
    read -rp "请选择 [0-10]: " choice

    case "$choice" in
      1) install_watch; pause ;;
      2) configure; reinstall_timer; pause ;;
      3) scan_watch; pause ;;
      4) status_watch; pause ;;
      5) show_logs; pause ;;
      6) test_tg; pause ;;
      7) reinstall_timer; pause ;;
      8) cleanup_reports; pause ;;
      9) update_self; pause ;;
      10) uninstall_watch; pause ;;
      0) exit 0 ;;
      *) echo "无效选择"; sleep 1 ;;
    esac
  done
}

case "${1:-menu}" in
  install) install_watch ;;
  config) configure ;;
  scan) scan_watch ;;
  status) status_watch ;;
  logs) show_logs ;;
  test) test_tg ;;
  timer) reinstall_timer ;;
  cleanup) cleanup_reports ;;
  update) update_self ;;
  uninstall) uninstall_watch ;;
  menu) menu ;;
  *) echo "用法: $0 {menu|install|config|scan|status|logs|test|timer|cleanup|update|uninstall}" ;;
esac

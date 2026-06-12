#!/system/bin/sh

MODDIR=${MODDIR:-${0%/*}}
LOGFILE=${LOGFILE:-$MODDIR/service.log}
MODULE_PROP=${MODULE_PROP:-$MODDIR/module.prop}
HOLIDAY_CACHE=${HOLIDAY_CACHE:-$MODDIR/holiday_year.txt}
TRIGGER_TIMES=${TRIGGER_TIMES:-"08:10 17:30"}

# --- 文件锁 (基于 mkdir 原子性，兼容无 flock 环境) ---
acquire_lock() {
  LOCK_DIR="${MODDIR}/.lock"
  TIMEOUT=30
  COUNT=0
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    COUNT=$((COUNT + 1))
    if [ "$COUNT" -ge "$TIMEOUT" ]; then
      rmdir "$LOCK_DIR" 2>/dev/null || true
      mkdir "$LOCK_DIR" 2>/dev/null || true
      break
    fi
    sleep 1
  done
  return 0
}

release_lock() {
  rmdir "${MODDIR}/.lock" 2>/dev/null || true
}

# --- 日志 ---
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX}$*" >> "$LOGFILE"
}

# --- 日志轮转 (超过 512KB 则归档) ---
rotate_log_if_large() {
  MAX_SIZE=$((512 * 1024))
  if [ -f "$LOGFILE" ]; then
    SIZE=$(stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$SIZE" -gt "$MAX_SIZE" ] 2>/dev/null; then
      mv "$LOGFILE" "${LOGFILE}.old" 2>/dev/null || true
      log "log rotated (exceeded 512KB)"
    fi
  fi
}

# --- 模块状态更新 ---
update_module_status() {
  STATUS=$1
  [ -z "$STATUS" ] && return 0
  [ ! -f "$MODULE_PROP" ] && return 0

  DESC="当前状态: $STATUS"
  TMP_PROP="${MODULE_PROP}.tmp"
  # 转义 sed 替换内容中的特殊字符 (/, &, \)
  DESC_ESCAPED=$(echo "$DESC" | sed 's/[\/&]/\\&/g')

  acquire_lock
  if grep -q '^description=' "$MODULE_PROP" 2>/dev/null; then
    sed "s|^description=.*|description=$DESC_ESCAPED|" "$MODULE_PROP" > "$TMP_PROP" && mv "$TMP_PROP" "$MODULE_PROP"
  else
    cp "$MODULE_PROP" "$TMP_PROP" && {
      echo "description=$DESC"
    } >> "$TMP_PROP" && mv "$TMP_PROP" "$MODULE_PROP"
  fi
  release_lock
}

# --- 屏幕唤醒判断 ---
is_screen_awake() {
  if command -v dumpsys >/dev/null 2>&1; then
    dumpsys power 2>/dev/null | grep -qE 'mWakefulness=Awake|Display Power: state=ON|mInteractive=true'
    return $?
  fi
  return 1
}

# --- 唤醒屏幕 ---
wake_screen() {
  if is_screen_awake; then
    log "screen already awake"
    return 0
  fi

  log "waking screen"
  input keyevent 224 2>/dev/null || true
  sleep 1

  if ! is_screen_awake; then
    input keyevent 26 2>/dev/null || true
    sleep 1
  fi
}

# --- 尝试解锁非安全锁屏 (滑动手势 + 菜单键) ---
dismiss_keyguard_if_possible() {
  if command -v wm >/dev/null 2>&1; then
    wm dismiss-keyguard 2>/dev/null || true
    sleep 1
  fi

  input keyevent 82 2>/dev/null || true
  sleep 1
  input swipe 540 1800 540 600 200 2>/dev/null || true
  sleep 1
}

# --- 启动打卡 Activity ---
start_attendance_activity() {
  COMPONENT="${1:-com.tencent.wework/com.tencent.wework.enterprise.attendance.controller.AttendanceActivity2}"
  PACKAGE_NAME="${2:-com.tencent.wework}"
  START_LOG="${MODDIR}/launch_result.tmp"
  rm -f "$START_LOG"

  log "launch: warming up app via monkey"
  if command -v monkey >/dev/null 2>&1; then
    monkey -p "$PACKAGE_NAME" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
    sleep 2
  fi

  if command -v am >/dev/null 2>&1; then
    log "launch: trying am start"
    if am start --user 0 -f 0x14000000 -n "$COMPONENT" 2>&1 | tee "$START_LOG" >> "$LOGFILE"; then
      if ! grep -qiE 'error|exception|failed' "$START_LOG"; then
        rm -f "$START_LOG"
        return 0
      fi
    fi
    log "launch: am start did not succeed cleanly"
  fi

  if command -v cmd >/dev/null 2>&1; then
    log "launch: trying cmd activity start-activity"
    if cmd activity start-activity --user 0 -f 0x14000000 -n "$COMPONENT" 2>&1 | tee "$START_LOG" >> "$LOGFILE"; then
      if ! grep -qiE 'error|exception|failed' "$START_LOG"; then
        rm -f "$START_LOG"
        return 0
      fi
    fi
    log "launch: cmd activity did not succeed cleanly"
  fi

  if command -v monkey >/dev/null 2>&1; then
    log "launch: trying monkey fallback for $PACKAGE_NAME"
    if monkey -p "$PACKAGE_NAME" -c android.intent.category.LAUNCHER 1 2>&1 | tee "$START_LOG" >> "$LOGFILE"; then
      if ! grep -qiE 'error|exception|failed' "$START_LOG"; then
        rm -f "$START_LOG"
        return 0
      fi
    fi
    log "launch: monkey fallback did not succeed cleanly"
  fi

  rm -f "$START_LOG"
  return 1
}

# --- 网络请求 (curl/wget) ---
fetch_url() {
  URL=$1
  FETCH_TMP="${MODDIR}/fetch_response.tmp"
  FETCH_ERR="${MODDIR}/fetch_error.tmp"

  rm -f "$FETCH_TMP" "$FETCH_ERR"

  if command -v curl >/dev/null 2>&1; then
    log "fetch_url: trying curl"
    if curl -fsL --max-time 30 "$URL" > "$FETCH_TMP" 2> "$FETCH_ERR"; then
      cat "$FETCH_TMP"
      rm -f "$FETCH_TMP" "$FETCH_ERR"
      return 0
    fi
    log "fetch_url: curl failed: $(tr '\n' ' ' < "$FETCH_ERR")"

    log "fetch_url: trying curl -k"
    if curl -kfsL --max-time 30 "$URL" > "$FETCH_TMP" 2> "$FETCH_ERR"; then
      cat "$FETCH_TMP"
      rm -f "$FETCH_TMP" "$FETCH_ERR"
      return 0
    fi
    log "fetch_url: curl -k failed: $(tr '\n' ' ' < "$FETCH_ERR")"
  else
    log "fetch_url: curl not found"
  fi

  if command -v wget >/dev/null 2>&1; then
    log "fetch_url: trying wget"
    if wget -q -O "$FETCH_TMP" "$URL" 2> "$FETCH_ERR"; then
      cat "$FETCH_TMP"
      rm -f "$FETCH_TMP" "$FETCH_ERR"
      return 0
    fi
    log "fetch_url: wget failed: $(tr '\n' ' ' < "$FETCH_ERR")"

    log "fetch_url: trying wget --no-check-certificate"
    if wget --no-check-certificate -q -O "$FETCH_TMP" "$URL" 2> "$FETCH_ERR"; then
      cat "$FETCH_TMP"
      rm -f "$FETCH_TMP" "$FETCH_ERR"
      return 0
    fi
    log "fetch_url: wget --no-check-certificate failed: $(tr '\n' ' ' < "$FETCH_ERR")"
  else
    log "fetch_url: wget not found"
  fi

  rm -f "$FETCH_TMP" "$FETCH_ERR"
  return 1
}

# --- 解析并缓存节假日数据 ---
cache_holiday_result() {
  YEAR=$1
  RESULT=$2

  acquire_lock
  if [ -f "$HOLIDAY_CACHE" ]; then
    TMP=$(grep -v "^$YEAR-" "$HOLIDAY_CACHE")
    if [ -n "$TMP" ]; then
      echo "$TMP" > "$HOLIDAY_CACHE"
    else
      > "$HOLIDAY_CACHE"
    fi
  fi

  echo "$RESULT" | grep -oE '"[0-9]{2}-[0-9]{2}":\{"holiday":(true|false)' | \
    sed -E 's/"([0-9]{2}-[0-9]{2})":\{"holiday":(true|false)/\1 \2/' | \
    awk -v yr="$YEAR" '{
      date = yr"-"$1
      flag = ($2=="true") ? 1 : 0
      print date, flag
    }' >> "$HOLIDAY_CACHE"
  release_lock
}

# --- 拉取某年节假日数据 ---
fetch_year_holidays() {
  YEAR=$1
  MODE_LABEL=${2:-同步}

  log "$MODE_LABEL $YEAR 年节假日数据"
  update_module_status "$MODE_LABEL $YEAR 年节假日数据中"

  RESULT=$(fetch_url "https://timor.tech/api/holiday/year/$YEAR")
  if [ -z "$RESULT" ]; then
    log "$MODE_LABEL $YEAR 年节假日数据失败"
    update_module_status "$MODE_LABEL $YEAR 年节假日失败"
    return 1
  fi

  cache_holiday_result "$YEAR" "$RESULT"
  log "$MODE_LABEL $YEAR 年节假日数据完成"
  update_module_status "$MODE_LABEL完成，已更新 $YEAR 年节假日"
  return 0
}

# --- 加载用户自定义配置 (可覆盖 TRIGGER_TIMES 等变量) ---
[ -f "$MODDIR/custom.sh" ] && . "$MODDIR/custom.sh"
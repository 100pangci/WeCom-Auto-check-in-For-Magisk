#!/system/bin/sh

MODDIR=/data/adb/modules/auto_check_in
LOGFILE=$MODDIR/service.log
MODULE_PROP=$MODDIR/module.prop
COMPONENT="com.tencent.wework/com.tencent.wework.enterprise.attendance.controller.AttendanceActivity2"
PACKAGE_NAME="com.tencent.wework"
TRIGGER_TIMES="08:10 17:30"
# 全年节假日缓存，格式: 每行 "YYYY-MM-DD 0|1"，0=需打卡 1=跳过
HOLIDAY_CACHE=$MODDIR/holiday_year.txt
LOG_PREFIX=""

. "$MODDIR/common.sh"

is_screen_awake() {
  if command -v dumpsys >/dev/null 2>&1; then
    dumpsys power 2>/dev/null | grep -qE 'mWakefulness=Awake|Display Power: state=ON|mInteractive=true'
    return $?
  fi
  return 1
}

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

start_attendance_activity() {
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

get_next_trigger_label() {
  NOW_TIME=${1:-$(date +%H:%M)}

  for T in $TRIGGER_TIMES; do
    if [ "$NOW_TIME" \< "$T" ]; then
      echo "今日 $T"
      return 0
    fi
  done

  FIRST_TRIGGER=$(echo "$TRIGGER_TIMES" | awk '{print $1}')
  echo "明日 $FIRST_TRIGGER"
}

update_idle_status() {
  NEXT_TRIGGER=$(get_next_trigger_label "$1")
  update_module_status "服务运行中，下次触发: $NEXT_TRIGGER"
}

# 确保当年数据已缓存；12月时预取下一年
ensure_holidays_cached() {
  YEAR=$(date +%Y)
  if ! grep -q "^$YEAR-" "$HOLIDAY_CACHE" 2>/dev/null; then
    log "fetching holiday data for $YEAR"
    fetch_year_holidays "$YEAR" "同步" || log "fetch $YEAR failed, will use weekday fallback"
  fi
  MONTH=$(date +%m)
  NEXT=$((YEAR + 1))
  if [ "$MONTH" = "12" ] && ! grep -q "^$NEXT-" "$HOLIDAY_CACHE" 2>/dev/null; then
    log "fetching holiday data for $NEXT"
    fetch_year_holidays "$NEXT" "同步" || true
  fi
}

is_workday() {
  TODAY=$(date +%Y-%m-%d)
  LINE=$(grep "^$TODAY " "$HOLIDAY_CACHE" 2>/dev/null | tail -1)
  if [ -n "$LINE" ]; then
    TYPE=$(echo "$LINE" | cut -d' ' -f2)
    # 1=节假日跳过, 0=调休需打卡
    return "$TYPE"
  fi
  # 不在特殊列表：按周几，周六日跳过
  DOW=$(date +%u)
  [ "$DOW" -ge 6 ] && return 1 || return 0
}

launch_attendance() {
  log "trigger launch $COMPONENT"
  update_module_status "正在打开企业微信打卡界面 ($NOW)"
  wake_screen
  dismiss_keyguard_if_possible

  if start_attendance_activity; then
    sleep 1
    log "launch complete"
    update_module_status "已触发打卡界面 ($NOW)"
    return 0
  fi

  log "launch failed after all fallbacks"
  update_module_status "打开打卡界面失败 ($NOW)"
  return 1
}

log "auto_check_in service started"
update_module_status "服务启动中"
update_module_status "开机等待 60 秒后初始化"
sleep 60

ensure_holidays_cached
update_idle_status

LAST_TRIGGER=""
while true; do
  NOW=$(date +%H:%M)
  # 每天 00:01 检测跨年
  if [ "$NOW" = "00:01" ] && [ "$LAST_TRIGGER" != "00:01" ]; then
    ensure_holidays_cached
    update_idle_status "$NOW"
    LAST_TRIGGER="00:01"
  fi
  for T in $TRIGGER_TIMES; do
    if [ "$NOW" = "$T" ] && [ "$LAST_TRIGGER" != "$NOW" ]; then
      if is_workday; then
        launch_attendance
        update_idle_status "$NOW"
      else
        log "holiday/weekend detected, skip launch"
        update_module_status "今日跳过打卡 ($NOW，节假日/周末)"
        update_idle_status "$NOW"
      fi
      LAST_TRIGGER="$NOW"
      break
    fi
  done
  if [ "$NOW" != "$LAST_TRIGGER" ]; then
    LAST_TRIGGER=""
  fi
  sleep 20
done

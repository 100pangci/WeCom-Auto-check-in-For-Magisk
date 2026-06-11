#!/system/bin/sh

MODDIR=/data/adb/modules/auto_check_in
LOGFILE=$MODDIR/service.log
MODULE_PROP=$MODDIR/module.prop
COMPONENT="com.tencent.wework/com.tencent.wework.enterprise.attendance.controller.AttendanceActivity2"
TRIGGER_TIMES="08:10 17:30"
# 全年节假日缓存，格式: 每行 "YYYY-MM-DD 0|1"，0=需打卡 1=跳过
HOLIDAY_CACHE=$MODDIR/holiday_year.txt
LOG_PREFIX=""

. "$MODDIR/common.sh"

wake_screen() {
  input keyevent 26 2>/dev/null || true
  sleep 1
  input keyevent 224 2>/dev/null || true
  sleep 1
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
  if command -v cmd >/dev/null 2>&1; then
    cmd activity start-activity --user 0 -n "$COMPONENT" --activity-clear-task 2>&1 >> "$LOGFILE"
  else
    am start --user 0 -n "$COMPONENT" -a android.intent.action.MAIN -c android.intent.category.LAUNCHER 2>&1 >> "$LOGFILE"
  fi
  sleep 1
  log "launch complete"
  update_module_status "已触发打卡界面 ($NOW)"
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

#!/system/bin/sh

LOGFILE=/data/adb/modules/auto_check_in/service.log
COMPONENT="com.tencent.wework/com.tencent.wework.enterprise.attendance.controller.AttendanceActivity2"
TRIGGER_TIMES="08:10 17:30"
# 全年节假日缓存，格式: 每行 "YYYY-MM-DD 0|1"，0=需打卡 1=跳过
HOLIDAY_CACHE=/data/adb/modules/auto_check_in/holiday_year.txt

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"
}

wake_screen() {
  input keyevent 26 2>/dev/null || true
  sleep 1
  input keyevent 224 2>/dev/null || true
  sleep 1
}

# 拉取指定年份全年节假日，写入缓存
# API: https://timor.tech/api/holiday/year/YYYY
# JSON 格式: {"code":0,"holiday":{"MM-DD":{"holiday":true/false,...},...}}
# holiday=true  -> 节假日，跳过(1)
# holiday=false -> 调休补班，打卡(0)
# 不在列表 -> 普通工作日/周末，按周几判断
fetch_year_holidays() {
  YEAR=$1
  log "fetching holiday data for $YEAR"
  RESULT=$(curl -sf --max-time 30 "https://timor.tech/api/holiday/year/$YEAR" 2>/dev/null)
  [ -z "$RESULT" ] && return 1

  # 先删除该年旧缓存行，避免重复
  if [ -f "$HOLIDAY_CACHE" ]; then
    TMP=$(grep -v "^$YEAR-" "$HOLIDAY_CACHE")
    echo "$TMP" > "$HOLIDAY_CACHE"
  fi

  # 解析: 提取 "MM-DD":{"holiday":true 或 false
  # 输出格式: YYYY-MM-DD 1(节假日) 或 YYYY-MM-DD 0(调休)
  echo "$RESULT" | grep -oE '"[0-9]{2}-[0-9]{2}":\{"holiday":(true|false)' | \
    sed 's/"//g; s/:{\"holiday\"://g' | \
    awk -v yr="$YEAR" '{
      split($1, a, ":")
      date = yr"-"a[1]
      flag = (a[2]=="true") ? 1 : 0
      print date, flag
    }' >> "$HOLIDAY_CACHE"

  log "holiday data for $YEAR cached"
  return 0
}

# 确保当年数据已缓存；12月时预取下一年
ensure_holidays_cached() {
  YEAR=$(date +%Y)
  if ! grep -q "^$YEAR-" "$HOLIDAY_CACHE" 2>/dev/null; then
    fetch_year_holidays "$YEAR" || log "fetch $YEAR failed, will use weekday fallback"
  fi
  MONTH=$(date +%m)
  NEXT=$((YEAR + 1))
  if [ "$MONTH" = "12" ] && ! grep -q "^$NEXT-" "$HOLIDAY_CACHE" 2>/dev/null; then
    fetch_year_holidays "$NEXT" || true
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
  wake_screen
  if command -v cmd >/dev/null 2>&1; then
    cmd activity start-activity --user 0 -n "$COMPONENT" --activity-clear-task 2>&1 >> "$LOGFILE"
  else
    am start --user 0 -n "$COMPONENT" -a android.intent.action.MAIN -c android.intent.category.LAUNCHER 2>&1 >> "$LOGFILE"
  fi
  sleep 1
  log "launch complete"
}

log "auto_check_in service started"
sleep 20

ensure_holidays_cached

LAST_TRIGGER=""
while true; do
  NOW=$(date +%H:%M)
  # 每天 00:01 检测跨年
  if [ "$NOW" = "00:01" ] && [ "$LAST_TRIGGER" != "00:01" ]; then
    ensure_holidays_cached
    LAST_TRIGGER="00:01"
  fi
  for T in $TRIGGER_TIMES; do
    if [ "$NOW" = "$T" ] && [ "$LAST_TRIGGER" != "$NOW" ]; then
      if is_workday; then
        launch_attendance
      else
        log "holiday/weekend detected, skip launch"
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

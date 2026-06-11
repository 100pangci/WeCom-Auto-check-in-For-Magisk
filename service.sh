#!/system/bin/sh

MODDIR=/data/adb/modules/auto_check_in
LOGFILE=$MODDIR/service.log
MODULE_PROP=$MODDIR/module.prop
COMPONENT="com.tencent.wework/com.tencent.wework.enterprise.attendance.controller.AttendanceActivity2"
TRIGGER_TIMES="08:10 17:30"
# 全年节假日缓存，格式: 每行 "YYYY-MM-DD 0|1"，0=需打卡 1=跳过
HOLIDAY_CACHE=$MODDIR/holiday_year.txt

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"
}

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

update_module_status() {
  STATUS=$1
  [ -z "$STATUS" ] && return 0
  [ ! -f "$MODULE_PROP" ] && return 0

  DESC="当前状态: $STATUS"
  TMP_PROP="${MODULE_PROP}.tmp"

  if grep -q '^description=' "$MODULE_PROP" 2>/dev/null; then
    sed "s|^description=.*|description=$DESC|" "$MODULE_PROP" > "$TMP_PROP" && mv "$TMP_PROP" "$MODULE_PROP"
  else
    cp "$MODULE_PROP" "$TMP_PROP" && {
      echo "description=$DESC"
    } >> "$TMP_PROP" && mv "$TMP_PROP" "$MODULE_PROP"
  fi
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
  update_module_status "同步 $YEAR 年节假日数据中"
  RESULT=$(fetch_url "https://timor.tech/api/holiday/year/$YEAR")
  if [ -z "$RESULT" ]; then
    log "fetch holiday data for $YEAR failed in current shell environment"
    update_module_status "$YEAR 年节假日数据同步失败"
    return 1
  fi

  # 先删除该年旧缓存行，避免重复
  if [ -f "$HOLIDAY_CACHE" ]; then
    TMP=$(grep -v "^$YEAR-" "$HOLIDAY_CACHE")
    echo "$TMP" > "$HOLIDAY_CACHE"
  fi

  # 解析: 提取 "MM-DD":{"holiday":true 或 false
  # 输出格式: YYYY-MM-DD 1(节假日) 或 YYYY-MM-DD 0(调休)
  echo "$RESULT" | grep -oE '"[0-9]{2}-[0-9]{2}":\{"holiday":(true|false)' | \
    sed -E 's/"([0-9]{2}-[0-9]{2})":\{"holiday":(true|false)/\1 \2/' | \
    awk -v yr="$YEAR" '{
      date = yr"-"$1
      flag = ($2=="true") ? 1 : 0
      print date, flag
    }' >> "$HOLIDAY_CACHE"

  log "holiday data for $YEAR cached"
  update_module_status "$YEAR 年节假日数据已同步"
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
  update_module_status "正在打开企业微信打卡界面 ($NOW)"
  wake_screen
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
update_module_status "服务运行中，等待触发: $TRIGGER_TIMES"

LAST_TRIGGER=""
while true; do
  NOW=$(date +%H:%M)
  # 每天 00:01 检测跨年
  if [ "$NOW" = "00:01" ] && [ "$LAST_TRIGGER" != "00:01" ]; then
    ensure_holidays_cached
    update_module_status "服务运行中，节假日缓存已检查"
    LAST_TRIGGER="00:01"
  fi
  for T in $TRIGGER_TIMES; do
    if [ "$NOW" = "$T" ] && [ "$LAST_TRIGGER" != "$NOW" ]; then
      if is_workday; then
        launch_attendance
      else
        log "holiday/weekend detected, skip launch"
        update_module_status "今日跳过打卡 ($NOW，节假日/周末)"
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

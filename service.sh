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

# --- 判断今天是否为工作日 ---
# 返回值: 0=工作日(需打卡)  1=节假日/周末(跳过)
is_workday() {
  TODAY=$(date +%Y-%m-%d)
  LINE=$(grep "^$TODAY " "$HOLIDAY_CACHE" 2>/dev/null | tail -1)
  if [ -n "$LINE" ]; then
    TYPE=$(echo "$LINE" | cut -d' ' -f2)
    # 缓存格式: 1=节假日(跳过打卡)  0=调休(需打卡)
    if [ "$TYPE" = "1" ]; then
      return 1  # 跳过
    else
      return 0  # 需打卡
    fi
  fi
  # 不在特殊列表：按周几判断
  DOW=$(date +%u)
  if [ "$DOW" -ge 6 ]; then
    return 1  # 周末，跳过
  fi
  return 0  # 工作日，需打卡
}

# --- 获取下次触发时间的描述标签 ---
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

# --- 确保当年数据已缓存；12月时预取下一年 ---
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

# --- 拉起打卡 (锁屏唤醒 + 解锁 + 启动 Activity) ---
launch_attendance() {
  log "trigger launch $COMPONENT"
  update_module_status "正在打开企业微信打卡界面 ($NOW)"
  wake_screen
  dismiss_keyguard_if_possible

  if start_attendance_activity "$COMPONENT" "$PACKAGE_NAME"; then
    sleep 1
    log "launch complete"
    update_module_status "已触发打卡界面 ($NOW)"
    return 0
  fi

  log "launch failed after all fallbacks"
  update_module_status "打开打卡界面失败 ($NOW)"
  return 1
}

# ========== 主流程 ==========

rotate_log_if_large
log "auto_check_in service started"
update_module_status "开机等待 60 秒后初始化"
sleep 60

ensure_holidays_cached
update_idle_status

LAST_TRIGGER=""
TRIGGER_TS_LIST=""
# 将触发时间转换为分钟数用于精确比较
for T in $TRIGGER_TIMES; do
  H=${T%:*}
  M=${T#*:}
  TRIGGER_TS_LIST="$TRIGGER_TS_LIST $((10#$H * 60 + 10#$M))"
done

while true; do
  rotate_log_if_large
  NOW=$(date +%H:%M)
  NOW_TS=$(( $(date +%-H) * 60 + $(date +%-M) ))

  # 每天 00:01 检测跨年
  if [ "$NOW" = "00:01" ] && [ "$LAST_TRIGGER" != "00:01" ]; then
    ensure_holidays_cached
    update_idle_status "$NOW"
    LAST_TRIGGER="00:01"
  fi

  # 检查每个触发时间是否到达
  for T in $TRIGGER_TIMES; do
    if [ "$NOW" = "$T" ] && [ "$LAST_TRIGGER" != "$NOW" ]; then
      if is_workday; then
        launch_attendance
      else
        log "holiday/weekend detected, skip launch"
        update_module_status "今日跳过打卡 ($NOW，节假日/周末)"
      fi
      update_idle_status "$NOW"
      LAST_TRIGGER="$NOW"
      break
    fi
  done

  # 跨分钟时重置 LAST_TRIGGER，确保下次能触发
  if [ "$NOW" != "$LAST_TRIGGER" ]; then
    LAST_TRIGGER=""
  fi

  # 智能 sleep: 计算距下一个触发时间的秒数，减少无效轮询
  NEXT_SLEEP=20
  NEXT_TRIGGER_TS=""
  for TS in $TRIGGER_TS_LIST; do
    if [ "$TS" -gt "$NOW_TS" ]; then
      NEXT_TRIGGER_TS=$TS
      break
    fi
  done
  if [ -z "$NEXT_TRIGGER_TS" ]; then
    # 所有触发时间已过，计算到明天第一个触发时间的分钟数
    FIRST_TS=$(echo "$TRIGGER_TS_LIST" | awk '{print $1}')
    NEXT_TRIGGER_TS=$((FIRST_TS + 1440))
  fi
  NEXT_SLEEP=$(( (NEXT_TRIGGER_TS - NOW_TS) * 60 ))
  # 最多 sleep 60 秒，避免一次性 sleep 太久错过中间的跨年检测
  if [ "$NEXT_SLEEP" -gt 60 ] || [ "$NEXT_SLEEP" -le 0 ] 2>/dev/null; then
    NEXT_SLEEP=20
  fi
  sleep "$NEXT_SLEEP"
done
#!/system/bin/sh

LOGFILE=/data/adb/modules/auto_check_in/service.log
COMPONENT="com.tencent.wework/com.tencent.wework.enterprise.attendance.controller.AttendanceActivity2"
TRIGGER_TIMES="08:10 17:30"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOGFILE"
}

wake_screen() {
  input keyevent 26 2>/dev/null || true
  sleep 1
  input keyevent 224 2>/dev/null || true
  sleep 1
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
LAST_TRIGGER=""
while true; do
  NOW=$(date +%H:%M)
  for T in $TRIGGER_TIMES; do
    if [ "$NOW" = "$T" ] && [ "$LAST_TRIGGER" != "$NOW" ]; then
      launch_attendance
      LAST_TRIGGER="$NOW"
      break
    fi
  done
  if [ "$NOW" != "$LAST_TRIGGER" ]; then
    LAST_TRIGGER=""
  fi
  sleep 20
done

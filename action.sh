#!/system/bin/sh

MODDIR=${0%/*}
LOGFILE=$MODDIR/service.log
MODULE_PROP=$MODDIR/module.prop
HOLIDAY_CACHE=$MODDIR/holiday_year.txt

ui_print() {
  echo "$1"
}

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [action] $*" >> "$LOGFILE"
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

fetch_year_holidays() {
  YEAR=$1
  log "manual fetching holiday data for $YEAR"
  update_module_status "手动同步 $YEAR 年节假日数据中"
  RESULT=$(fetch_url "https://timor.tech/api/holiday/year/$YEAR")
  if [ -z "$RESULT" ]; then
    log "manual fetch holiday data for $YEAR failed"
    update_module_status "手动同步 $YEAR 年节假日失败"
    return 1
  fi

  if [ -f "$HOLIDAY_CACHE" ]; then
    TMP=$(grep -v "^$YEAR-" "$HOLIDAY_CACHE")
    echo "$TMP" > "$HOLIDAY_CACHE"
  fi

  echo "$RESULT" | grep -oE '"[0-9]{2}-[0-9]{2}":\{"holiday":(true|false)' | \
    sed -E 's/"([0-9]{2}-[0-9]{2})":\{"holiday":(true|false)/\1 \2/' | \
    awk -v yr="$YEAR" '{
      date = yr"-"$1
      flag = ($2=="true") ? 1 : 0
      print date, flag
    }' >> "$HOLIDAY_CACHE"

  log "manual holiday data for $YEAR cached"
  update_module_status "手动同步完成，已更新 $YEAR 年节假日"
  return 0
}

YEAR=$(date +%Y)

ui_print "- WeCom Auto Check-in"
ui_print "- 手动拉取 $YEAR 年节假日清单中..."

if fetch_year_holidays "$YEAR"; then
  ui_print "- 节假日清单拉取成功"
  ui_print "- 缓存文件: $HOLIDAY_CACHE"
  exit 0
else
  ui_print "- 节假日清单拉取失败，请查看 $LOGFILE"
  exit 1
fi
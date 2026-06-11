#!/system/bin/sh

MODDIR=${0%/*}
LOGFILE=$MODDIR/service.log
MODULE_PROP=$MODDIR/module.prop
HOLIDAY_CACHE=$MODDIR/holiday_year.txt
LOG_PREFIX="[action] "

. "$MODDIR/common.sh"

ui_print() {
  echo "$1"
}

YEAR=$(date +%Y)

ui_print "- WeCom Auto Check-in"
ui_print "- 手动拉取 $YEAR 年节假日清单中..."

if fetch_year_holidays "$YEAR" "手动同步"; then
  ui_print "- 节假日清单拉取成功"
  ui_print "- 缓存文件: $HOLIDAY_CACHE"
  exit 0
else
  ui_print "- 节假日清单拉取失败，请查看 $LOGFILE"
  exit 1
fi
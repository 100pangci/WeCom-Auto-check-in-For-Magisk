# WeCom Auto Check-in For Magisk

自动在手机时间 08:10 和 17:30 打开企业微信考勤页面 `com.tencent.wework.enterprise.attendance.controller.AttendanceActivity2`。
支持跳过节假日，周末，并在调休日打卡。

## 安装方法

1. 下载release中的模块。
2. 在 Magisk 中安装该模块。
3. 重启手机。

## 特性

- 采用 `service.sh` 服务脚本在启动后常驻
- 在到达目标时间时自动唤醒屏幕并打开指定活动
- 保持屏幕锁定状态，不尝试绕过 Android 安全锁屏
- GitHub Actions 可直接构建未签名的 zip

## 注意

- 模块会尝试唤醒屏幕并打开考勤界面，但不会解除系统锁屏（PIN/图案/密码）。
- 只要到达目标界面，企业微信即可继续完成自动打卡（前提是应用本身已配置好打卡逻辑）。
- 该服务在设备开机且模块启用后会常驻后台，所以每天 08:10 和 17:30 都能触发。
- 目标应用包名为 `com.tencent.wework`，请确保企业微信已安装。

## 为什么做这个模块

- TMD劳资早上来早了一点忘打卡了。
- TM这个月全勤奖没了。

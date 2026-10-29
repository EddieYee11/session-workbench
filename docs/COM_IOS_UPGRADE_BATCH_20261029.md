# Com iOS 升级批次 · 2026-10-29

分支：`com-ios-upgrade-batch-20261029`  
范围：iOS + 必要后端；Android 停更；网页只跟 API 契约。

## 本批已落地

### 产品闭环
- **记账快路径**：扩充餐饮/出行等口语词表；`花的` 视为花费；新增用例「茶五元」「午饭花的21」「美团外卖」。
- **统一「等你」**：`waitingInboxCount` = 审批/待验收 + `/personal/waiting`；今天右上角、舞台 chip、头像菜单第一项、Dock「今天」角标、灵动岛 waiting 字段、深链 `com-eddie://waiting`、审批类本地通知 `comSection=waiting` 都进同一 `WaitingSheet`。
- **Bark**：`task-result:case-wait:*` 深链改为 `com-eddie://waiting`。
- **下一步**：一卡一主动作；其余收进「更多」；交给 Com 成功触感 + pop 打开航程。

### UI / 动效
- `DesignSystem.Motion`：`snap` / `settle` / `pop` / `flight` / `rise` / `lift` + `EnterRise` + `AmbientMotionPolicy`。
- Today / Health 进场共用 `EnterRise`；Dock / 发送飞行挂到 Motion tokens；角色 Timeline 走 AmbientMotionPolicy。
- README 叙事对齐五 Tab + 等你；标明 Android 停更、web 为配套端。

## 验证
- 本机直接断言 `fast_bookkeeping.parse` 通过（环境缺 pytest 时未跑整套）。
- iOS 未在本机连模拟器编译；建议：`--ui-testing` 走五 Tab、打开 Waiting、下一步「更多」、Reduce Motion。
- Bark / 真机记账快路径待装机联调。

## 未做 / 下一批
- Gmail 等新连接器
- 网页视觉大改（仅 API 不破）
- Instruments 动效校准
- 五 Tab → 三 Tab（本批明确不做）

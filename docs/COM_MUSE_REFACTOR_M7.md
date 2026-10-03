# M7 1.8.0 安装与验证

2026-10-03，M0–M6各自提交保留。当前包work.eddie.sessions，versionCode18/versionName1.8.0。

- mini后端全回归380项通过；MBP376项通过/3项可选依赖跳过/1项旧Node22.12环境失败，改用现有22.22.1重跑该项通过。
- Android testDebugUnitTest、assembleDebug、assembleDebugAndroidTest、assembleBenchmark通过；完整模拟器UI 66项通过（新增补充3项、产物/步骤3项）。
- mini同一Syncthing源码部署，公私网health为1.8.0，完整权限保留，goals_scheduler=false。
- 同证书覆盖安装到Xiaomi2608BPX34C，保留数据与配对；证书SHA256 d01d14be850e7386ca77b2bbb1d5b9d36282b84f12cc70d6bde8e5ec8780434a。
- 20:45:49安装1.8.0并启动MainActivity。APK为verification/com-1.8.0/Com-1.8.0.apk，SHA256 785a1ae307f05980ef08e2c2f6016b6a3412cf926a9f2aa990950c227d61c116。

验收范围：模拟器覆盖导航/返回/消息卡/数量上限/今天计数/断网缓存/unknown/补充状态/步骤产物；没有向真实主会话发送探针或改生产账本。长任务真实模型执行与双任务拆分由路由提示词与隔离源/派发测试核验，不能把提示词测试当真实生产消息验收。实体语音、折叠切换、系统后台与通知仍需用户亲测。窄宽屏/字体/键盘证据沿既有UI体验测试与M1/M2截图；本轮未逐一重新截图全部组合。

无数据库迁移，无push/tag/release。任务B继续在此版本基础上开发，B4–B6只交提案。

## 1.8.1最终补验（取代上面的缺口说明）

最终后端403、JVM67、全UI71通过；窄屏/宽屏/1.3字体/键盘/长标题/空数据/缓存/真正网络错误都有本轮截图。真实原生Pi在隔离Com库中确认问候/快速查询0任务、长事项1、独立两件2，来源与标题匹配，不启动探针执行器、不写生产主会话或台账。快速查询用空测试集，不能代表真实账本金额。最终APK、安装与实体待确认项见COM_B_DELIVERY_REPORT.md。

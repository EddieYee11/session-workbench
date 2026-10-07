# 雷鸟 iO → Com! · iOS 可行性核对

2026-10-07。用户要求检查，眼镜当前未配对/不在手边。本轮不改绑定、不刷固件、不替换雷鸟 App。

结论：Turbo-IO 有 iOS 语音→自定义模型→镜片回显基础，可以接 Com；当前 Com iOS 本身没有 iO BLE/协议/眼镜 ASR，不能把普通蓝牙麦克风选项当成已打通。

## 推荐接入路径

眼镜 → 兼容的雷鸟官方 iOS App + Turbo-IO V2 → 官方 ASR → Com 眼镜专用 HTTPS 接口 → Com 主对话/实际执行器 → 流式回答 → 官方回显。

- 上游 [扩展说明](https://github.com/Turbo1123/Turbo-IO/blob/main/official-addon/README.md) 提供自定义 HTTPS 模型入口，Key 存钥匙串；保留官方识别、配对及显示。
- 源码 [Core.m](https://github.com/Turbo1123/Turbo-IO/blob/main/official-addon/Core.m) 的 `TIOChatRequest` 生成 model、stream=true、messages，但没有 Com 必需的稳定 request_id；`Addon.m` 可配置完整 chat/completions URL、模型、Key。因此不能只填地址就宣称完全兼容。
- 适配需给每次新眼镜问题生成稳定 ID，断线重连沿用同一 ID；模型 `com-personal`，接口 `https://pi.eddiegao.work:8443/sessions/rayneo/v1/chat/completions`。使用专用眼镜令牌，不暴露手机主权限；查询原请求回执，不重放记账等操作。
- Com `backend/rayneo.py` 已有配对、专用令牌、请求去重、流式输出和真实结果核实。本轮从 mini 对公网眼镜 health 实际请求，返回 ok=true、com-rayneo、com-personal。已有 Android derivative 在本机保留，iOS 对应定制未实现。
- V2 构建需要兼容官方应用输入及本人签名，不能把普通商店加密 App 当成已合并插件。现有来源/签名未核验，暂未制作或安装 iOS 雷鸟扩展。

另一路是 [V1 独立 SDK](https://github.com/Turbo1123/Turbo-IO)：可研究配对、录音、ASR及显示，工作量更大；切换客户端会影响现有绑定。当前不迁入 Com、不争抢连接。

## 验收边界

已核对：上游说明、具体请求字段、Com 接口契约及公网响应。未核对：这副眼镜固件、iPhone 配对、语音识别、镜片回答、后台追问。眼镜在手边后，按确切 iOS 宿主版本构建适配，再测短问答→同请求重连→实际指令/回执→镜片确认。

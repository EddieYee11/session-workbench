# Come Up (Com!) 生产级全双工实时语音对话系统：技术调研、架构设计与落地规范白皮书

> **文档标识**：`COM-DOC-VOICE-20261110-M2`  
> **核心归属**：Come Up（Com! 个人全功能语音助手系统）  
> **版本**：v2.0.0 (Production Architecture Edition)  
> **责任团队**：Teamwork Voice Architecture Taskforce (Milestone M1–M2)  
> **文档位置**：`work/工具与效率/会话工作台/docs/AI_REALTIME_VOICE_RESEARCH.md`  

---

## 目录 (Table of Contents)
1. [执行摘要与核心决策 (Executive Summary & Architectural Decisions)](#1-执行摘要与核心决策)
2. [第一部分：主流实时语音架构深度调研与多维对比](#2-第一部分主流实时语音架构深度调研与多维对比)
   - 2.1 [OpenAI Realtime API (GPT-4o Realtime)](#21-openai-realtime-api)
   - 2.2 [Google Gemini Multimodal Live API (Vertex AI BidiGenerateContent)](#22-google-gemini-multimodal-live-api)
   - 2.3 [级联管道方案 (Cascaded Pipeline: ASR + LLM + TTS)](#23-级联管道方案-cascaded-pipeline)
   - 2.4 [端到端全双工开源与前沿模型 (Moshi, MiniMax, Qwen-Omni)](#24-端到端全双工开源与前沿模型)
   - 2.5 [核心技术维度横向对比矩阵 (WebRTC vs WebSocket, TTFA 耗时分解, Barge-in)](#25-核心技术维度横向对比矩阵)
3. [第二部分：Come Up 生产级全双工语音系统架构设计](#3-第二部分come-up-生产级全双工语音系统架构设计)
   - 3.1 [端到端流转拓扑与连接架构](#31-端到端流转拓扑与连接架构)
   - 3.2 [通信协议标准 (Wire Protocol Specification)](#32-通信协议标准-wire-protocol-specification)
   - 3.3 [代际隔离机制 (Generation Epoch Fencing Architecture)](#33-代际隔离机制-generation-epoch-fencing-architecture)
   - 3.4 [iOS 端音频管线与硬件 DSP 规范 (VoiceProcessingIO, AEC & Soft Ducking)](#34-ios-端音频管线与硬件-dsp-规范)
4. [第三部分：Personal Agent 业务能力融合与闭环持久化](#4-第三部分personal-agent-业务能力融合与闭环持久化)
   - 4.1 [实时流式 Tool Calling 规范与避坑要点](#41-实时流式-tool-calling-规范与避坑要点)
   - 4.2 [分层记忆架构与实时语音递进注入 (Progressive Memory Injection)](#42-分层记忆架构与实时语音递进注入)
   - 4.3 [通话结束全自动结构化提炼与多目标落盘 (Post-Call Persistence Pipeline)](#43-通话结束全自动结构化提炼与多目标落盘)
5. [第四部分：特色交互、多模态情绪感知与副通道附和](#5-第四部分特色交互多模态情绪感知与副通道附和)
   - 5.1 [多模态 5 维情绪感知与声学特征自适应](#51-多模态-5-维情绪感知与声学特征自适应)
   - 5.2 [iOS LiveVoiceOrb 流体圆球色温动效联动](#52-ios-livevoiceorb-流体圆球色温动效联动)
   - 5.3 [副通道拟人化倾听附和 (Backchanneling) 与毫秒级熔断](#53-副通道拟人化倾听附和-backchanneling-与毫秒级熔断)
6. [第五部分：后端网关适配器架构与代际隔离实现规划](#6-第五部分后端网关适配器架构与代际隔离实现规划)
   - 6.1 [`LiveUpstreamAdapter` 接口抽象体系](#61-liveupstreamadapter-接口抽象体系)
   - 6.2 [GeminiLiveAdapter, OpenAIRealtimeAdapter 与 MockLiveAdapter 设计](#62-geminiliveadapter-openairealtimeadapter-与-mockliveadapter-设计)
   - 6.3 [测试与验证基线 (Test Baseline & Integrity Standards)](#63-测试与验证基线)

---

## 1. 执行摘要与核心决策

### 1.1 背景与目标
Come Up（Com!）作为服务于 Eddie 的全功能私人 AI 伙伴，核心追求“像相识多年的老朋友般自然、松弛、全能且知根知底”。传统语音交互中“按键说话—静音等待—大段朗读”的半双工对讲机体验（延迟 >1.2s，机械且冷冰冰）已无法满足高频生产力与生活伴随要求。

本项目的战略目标是在 iOS 客户端（`ios/Com`）与 Python 异步网关（`backend/`）之间落地**生产级全双工实时语音对话系统**：
- **超低延迟交互**：端到端感知首音频包延迟（TTFA）稳定在 **500–750ms**。
- **双层自然打断 (Barge-in)**：结合端侧硬件级 AEC、动态自适应软衰减与服务端语义 VAD，并辅以严密的**代际隔离（Generation Epoch Fencing）**，彻底消除在途旧音频串流泄漏。
- **Personal Agent 全量深度继承**：在实时语音流中无缝执行记账（ezBookkeeping）、日程（Apple Calendar）、提醒事项（微信+日历双写）、下一步待办（NextSteps）与记忆库检索（memvec/Hindsight）。
- **通话终了全自动闭环沉淀**：挂断瞬间异步生成 Markdown/JSON 通话纪要，自动分流待办至 Obsidian，新事实写回 Com 记忆库。
- **拟人化特色互动**：5 维情绪感知驱动 iOS 流体圆球（`LiveVoiceOrb`）色彩与光晕变幻，配合微拟人停顿附和（Backchanneling）。

### 1.2 核心架构决策矩阵 (Architectural Decisions)

| 决策点 | 采纳方案 | 备选/容灾方案 | 核心决策理由 |
|---|---|---|---|
| **首选语音大模型引擎** | **Google Gemini 2.5 Flash Native Audio** (Vertex AI `LlmBidiService`) | **OpenAI GPT-4o Realtime API** | 500–750ms 超低 TTFA，原生 24kHz 输出与双向转写字幕，复用现有 GCP 开发者账号配额零增量 API 成本，原生支持未来图像/视频流扩展。 |
| **端云传输通信协议** | **全双工 WebSocket (TLS)** (上行 16kHz PCM16, 下行 24kHz PCM16 + JSON 控制) | WebRTC (SRTP/UDP + DataChannel) | iOS 原生 `URLSessionWebSocketTask` 零外部依赖，极低内存消耗；自建 Python 网关极易水平扩展与调试；避免 WebRTC 依赖包暴增 20MB 及复杂 ICE/TURN 运维。 |
| **打断 (Barge-in) 机制** | **双层混合协同打断** (端侧 RMS 自适应软衰减 + 服务端语义 VAD 确认) | 纯客户端能量截断 / 纯服务端 VAD | 兼顾毫秒级低延迟响应与抗环境底噪误触；消除生硬爆音。 |
| **在途音频串流防护** | **代际隔离计数器 (Generation Epoch Fencing)** | 时间戳过滤 / 暴力丢包 | 客户端与服务端维护同步单调递增 `epoch_id`，播放层对旧 epoch 帧一票否决，彻底解决网络乱序导致的打断后旧包串流回响。 |
| **后端适配层设计** | **抽象 `LiveUpstreamAdapter` 基类** (统一派发 Event 与 Audio) | 单一硬编码适配器 | 解耦具体服务商，内置 `GeminiLiveAdapter`、`OpenAIRealtimeAdapter`，并提供 100% 确定性全流控的 `MockLiveAdapter` 保障生产级 CI/CD 自动化测试。 |

---

## 2. 第一部分：主流实时语音架构深度调研与多维对比

### 2.1 OpenAI Realtime API

#### 2.1.1 协议机制与拓扑
OpenAI Realtime API 基于统一多模态 GPT-4o 架构，消除了独立 ASR 与 TTS 的文本级联延迟：
- **接入形式**：
  - **WebSocket 网关**：`wss://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview`。音频 Base64 编码内嵌于 JSON 消息（`input_audio_buffer.append`），信令交互结构清晰但有 33% 的 Base64 编码膨胀。
  - **WebRTC 直连**：通过 REST API（`POST /v1/realtime/sessions`）换取单次 Ephemeral Token，客户端创建 PeerConnection，音频经 SRTP/UDP 走原生 RTP 传输，信令走 DataChannel。
- **音频规范**：24kHz 16-bit 单声道 PCM（小端序），亦支持电信级 8kHz G.711 u-law/a-law。

#### 2.1.2 打断检测与截断时序
- **服务端 VAD (`server_vad`)**：内置静音等待窗口（通常配置 300–500ms）与灵敏度门限。
- **截断事件 (`conversation.item.truncated`)**：当打断触发时，服务端下发截断信令，指明 AI 输出音频被切断的具体毫秒偏移，随后紧跟 `response.cancelled`。客户端必须立即根据偏移清空未播缓冲区。

#### 2.1.3 优劣势与成本
- **优势**：英文语调感染力、细腻的重音与情感表达居于业界领先地位。
- **劣势**：输入音频 $40/1M tokens（约 $0.06/分），输出音频 $100/1M tokens（约 $0.24/分），长时间通话成本较高；国内直连访问不稳定，需配置海外网络节点。

---

### 2.2 Google Gemini Multimodal Live API

#### 2.2.1 协议机制与拓扑
Gemini Multimodal Live API 依托 Google 统一原生多模态 Transformer：
- **接入形式**：
  - **Vertex AI 企业级端点**：`wss://{location}-aiplatform.googleapis.com/ws/google.cloud.aiplatform.v1beta1.LlmBidiService/BidiGenerateContent`。
- **建连握手**：
  - 建立 WebSocket 后，客户端首先发送单个 `setup` JSON 载荷，配置模型、系统提示词、语音角色（Aoede, Kore, Puck, Charon, Fenrir）、VAD 灵敏度、双向转写开关与工具集合。
  - 服务端确认返回 `{"setupComplete": {}}` 即宣告通道就绪。
- **音频规范**：
  - **上行推流**：16,000Hz 16-bit Mono PCM，封装在 `realtimeInput.mediaChunks` 中。
  - **下行拉流**：24,000Hz 16-bit Mono PCM，服务端在 `serverContent.modelTurn.parts[].inlineData` 中连续下发。

#### 2.2.2 打断机制与原生双向实时字幕
- **打断下发**：当服务端检测到用户说话打断时，在 `serverContent` 中发送 `{"interrupted": true}`，信令极简明晰。
- **原生双向转写**：配置 `inputAudioTranscription` 与 `outputAudioTranscription` 后，网关无需接入外部 ASR 即可在同一通道中实时接收用户文字流与 AI 回复文字流（带 `finished: bool` 标识）。

#### 2.2.3 多项目容灾与生态契合度
Come Up 项目中已在 `backend/voice_live.py` 实现了基于 ADC (Application Default Credentials) 与 `gcloud` 令牌的进程级缓存机制，支持主项目 `project-816c0481-813e-4353-ab7` 与备用项目 `gen-lang-client-0792759409` 的跨账号跨地域自动容灾切换，依托既有 GCP 赠金可实现零额外成本生产级运行。

---

### 2.3 级联管道方案 (Cascaded Pipeline: ASR + LLM + TTS)

典型结构：
$$\text{PCM In} \xrightarrow{\text{VAD}} \text{ASR (SenseVoice/Whisper)} \xrightarrow{\text{Text}} \text{LLM (DeepSeek/Haiku)} \xrightarrow{\text{Tokens}} \text{Sentence Buffer} \xrightarrow{\text{Chunks}} \text{TTS (Cartesia/CosyVoice)} \xrightarrow{\text{PCM Out}}$$

- **延迟累加分析**：
  - ASR 流式识别：~150–250ms
  - LLM 首 Token 生成 (TTFT)：~200–350ms
  - 首句标点抢跑缓冲：~100–180ms
  - 流式 TTS 首包合成：~120–200ms
  - 综合首包时延达到 **900–1400ms**，存在明显卡顿滞后感。
- **致命痛点**：音频情感与语调语素在 ASR 阶段完全丢失；打断时需跨 ASR/LLM/TTS 三个独立系统级联取消，极易引发状态错乱与音频漏播。

---

### 2.4 端到端全双工开源与前沿模型

- **Kyutai Moshi (7B)**：采用 Mimi 神经编解码器与多流因果交互 Transformer。具备原生边听边说的附和能力（Backchanneling），但中文理解与生成能力极弱，且自部署需要高端 GPU 资源。
- **MiniMax Speech-to-Speech**：中文口语与情绪拟真度极高，提供商业 WebSocket 接口，是极佳的国内商业备份方案。
- **阿里 Qwen-Omni**：端到端全模态模型，前沿探索价值大，但目前缺少成熟低门槛的全双工双向托管 API。

---

### 2.5 核心技术维度横向对比矩阵

#### 2.5.1 传输协议对比：WebRTC vs WebSocket

| 指标 | WebRTC (SRTP/UDP + DataChannel) | WebSocket (TCP + TLS) | Come Up 选型结论 |
|---|---|---|---|
| **底层协议** | UDP，允许适当丢包以换取最低时延 | TCP，滑动窗口严格保序与可靠交付 | **选择 WebSocket** |
| **抗弱网丢包** | 强（内置 NACK/FEC/PLC） | 弱（队头阻塞可能引发延迟抖动） | 网关与手机局域网/优质 5G 传输下，TCP 损耗可忽略 |
| **iOS 客户端负担** | 极重（需集成 WebRTC/LiveKit C++ SDK，增重 20MB） | **极轻（iOS Foundation `URLSessionWebSocketTask` 零依赖）** | **WebSocket 完美契合 Come Up 轻量架构** |
| **NAT 穿透与网关运维** | 复杂（依赖 ICE/STUN/TURN 服务器集群） | **极简（标准 HTTPS 443 端口 Upgrade，零穿透障碍）** | **自建 Python FastAPI 网关部署极其简单** |

#### 2.5.2 端到端感知首音频包时延 (TTFA) 分解对比

$$\text{TTFA} = T_{\text{capture}} (50\text{ms}) + T_{\text{uplink}} (40\text{ms}) + T_{\text{VAD\_silence}} (400\text{ms}) + T_{\text{infer}} + T_{\text{downlink}} (40\text{ms}) + T_{\text{jitter\_buf}} (60\text{ms})$$

| 方案架构 | $T_{\text{infer}}$ (模型首包推理) | 综合 TTFA 感知延迟 | 交互主观感受 |
|---|---|---|---|
| **Gemini 2.5 Flash Native Audio** | **160 – 240 ms** | **610 – 830 ms** *(优网 550ms)* | **如真人面对面交谈，极其自然** |
| **OpenAI GPT-4o Realtime** | **200 – 300 ms** | **650 – 930 ms** | **流畅自然，感染力强** |
| **优化级联 (SenseVoice+DeepSeek+Cartesia)** | **480 – 700 ms** | **1070 – 1490 ms** | 能明显感知约 1 秒的等待停顿 |
| **普通级联 (Whisper+Mini+ElevenLabs)** | **700 – 1200 ms** | **1390 – 2090 ms** | 严重机械对讲感，缺乏日常交流意愿 |

---

## 3. 第二部分：Come Up 生产级全双工语音系统架构设计

### 3.1 端到端流转拓扑与连接架构

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                            iOS 客户端 (Swift 6.0)                            │
│                                                                              │
│  ┌─────────────────────────┐                   ┌──────────────────────────┐  │
│  │   AVAudioEngine InBus   │                   │  AVAudioPlayerNode       │  │
│  │   16kHz PCM16 Mono      │                   │  24kHz PCM16 Mono        │  │
│  │   Hardware AEC Active   │                   │  Adaptive Jitter Buffer  │  │
│  └────────────┬────────────┘                   └────────────▲─────────────┘  │
│               │ 100ms / 3200B Chunks                        │ 24kHz Audio    │
│               ▼                                             │ Epoch Filtered │
│  ┌─────────────────────────┐                   ┌────────────┴─────────────┐  │
│  │   Adaptive RMS Gate     │                   │  Epoch Fencing Receiver  │  │
│  │   (Barge-in Ducking)    │                   │  (Discard old epochs)    │  │
│  └────────────┬────────────┘                   └────────────▲─────────────┘  │
│               │                                             │                │
│               ├─ [Barge-in Trigger] ──> Soft Duck (15%)     │                │
│               │                         CoreHaptics Buzz    │                │
│               ▼                                             │                │
│  ┌──────────────────────────────────────────────────────────┴─────────────┐  │
│  │               URLSessionWebSocketTask (Full-Duplex TLS)                │  │
│  └────────────────────────────────────┬───────────────────────────────────┘  │
└───────────────────────────────────────┼──────────────────────────────────────┘
                                        │ Up: 16k PCM16 + JSON Controls
                                        │ Down: 24k PCM16 + JSON Events
                                        ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                    Come Up Python 实时流式网关 (FastAPI)                     │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │                     LiveSessionManager & Epoch State                   │  │
│  │  - HMAC Token 鉴权 (Timing Attack Safe)                                 │  │
│  │  - 单调递增 Epoch 序号控制器 (Epoch ID Tracker & Synchronizer)          │  │
│  │  - 双向状态机: IDLE ──> LISTENING ──> THINKING ──> SPEAKING            │  │
│  └──────────────────┬───────────────────────────────────────▲─────────────┘  │
│                     │                                       │                │
│                     ▼                                       │                │
│  ┌────────────────────────────────────────────────────────┐ │                │
│  │                LiveUpstreamAdapter 抽象基类             │ │                │
│  │  ┌────────────────────────┐  ┌───────────────────────┐ │ │                │
│  │  │   GeminiLiveAdapter    │  │  OpenAIRealtimeAdapter│ │ │                │
│  │  │ (Vertex AI Dual-Target)│  │  (Fallback Route)     │ │ │                │
│  │  └────────────────────────┘  └───────────────────────┘ │ │                │
│  │  ┌───────────────────────────────────────────────────┐ │ │                │
│  │  │   MockLiveAdapter (Deterministic E2E Test Engine) │ │ │                │
│  │  └───────────────────────────────────────────────────┘ │ │                │
│  └──────────────────┬─────────────────────────────────────┘ │                │
│                     │ Tool Execution                        │ Events / Audio │
│                     ▼                                       │                │
│  ┌────────────────────────────────────────────────────────┐ │                │
│  │             Personal Agent Tool Sandbox Layer          │ │                │
│  │  - ezBookkeeping 记账 (秒级时间戳)                      ├─┘                │
│  │  - Apple Calendar 日程 (【分类】标题)                   │                  │
│  │  - Reminder 双写 (微信提醒 + Calendar)                 │                  │
│  │  - 记忆检索 (memvec & Hindsight recall_on_demand)       │                  │
│  │  - 后台任务派发 (ask_com_main)                         │                  │
│  └──────────────────┬─────────────────────────────────────┘                  │
│                     │ On Hangup / Close                                      │
│                     ▼                                                        │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │           Post-Call Intelligence Pipeline (通话结束异步提炼落盘)         │  │
│  │  - 结构化纪要生成: records/YYYY-MM/<session_id>-summary.md             │  │
│  │  - 待办事项自动分流: Obsidian vault 任务/待处理/                       │  │
│  │  - 高置信度事实写回: _global/记忆库/Com/mem_*.md                      │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

### 3.2 通信协议标准 (Wire Protocol Specification)

#### 3.2.1 客户端上行至网关 (Client -> Server)
- **二进制帧 (Binary Frame)**：
  - 内容：原始 16,000Hz 16-bit Mono Linear PCM（小端序）。
  - 规格：每 100ms 一包（1600 采样点 = 3200 字节）。
- **文本控制帧 (JSON Text Frame)**：
  - **打断信令 (Interrupt)**：
    ```json
    { "type": "interrupt", "epoch": 2 }
    ```
  - **文本插话 (Text Turn)**：
    ```json
    { "type": "text", "text": "帮我看看这个月一共花了多少钱", "epoch": 2 }
    ```
  - **心跳保活 (Ping)**：
    ```json
    { "type": "ping" }
    ```
  - **主动挂断 (End Session)**：
    ```json
    { "type": "end" }
    ```

#### 3.2.2 网关下行至客户端 (Server -> Client)
- **二进制帧 (Binary Frame)**：
  - 内容：原始 24,000Hz 16-bit Mono Linear PCM（小端序）。直接送入客户端播放抖动缓冲。
- **文本控制帧 (JSON Text Frame)**：
  - **连接就绪 (Ready)**：
    ```json
    {
      "type": "ready",
      "session_id": "com-live-20261110-8f7a2c",
      "voice": "Aoede",
      "model": "gemini-live-2.5-flash-native-audio",
      "sample_rate_in": 16000,
      "sample_rate_out": 24000,
      "epoch": 1
    }
    ```
  - **实时语音转录 (Transcript)**：
    ```json
    {
      "type": "transcript",
      "role": "user",
      "text": "记一笔午饭三十五元",
      "finished": true,
      "epoch": 1
    }
    ```
    ```json
    {
      "type": "transcript",
      "role": "assistant",
      "text": "好的，已为你记下35元午饭，分类为餐饮外卖。",
      "finished": false,
      "epoch": 1
    }
    ```
    *(注：网关亦兼容保持 `user_transcript` 与 `assistant_transcript` 旧式信令)*。
  - **工具执行状态通知 (Tool Call)**：
    ```json
    {
      "type": "tool_call",
      "name": "bookkeeping_add",
      "arguments": {"amount": 35.0, "item": "午饭"},
      "title": "记账 ¥35 · 午饭",
      "status": "executing",
      "epoch": 1
    }
    ```
    执行完毕更新：
    ```json
    {
      "type": "tool_call",
      "name": "bookkeeping_add",
      "arguments": {"amount": 35.0, "item": "午饭"},
      "title": "已记账 ¥35 · 午饭",
      "status": "completed",
      "epoch": 1
    }
    ```
  - **确认打断通知 (Interrupted)**：
    ```json
    {
      "type": "interrupted",
      "epoch": 2
    }
    ```
  - **情绪感知信令 (Emotion)**：
    ```json
    {
      "type": "emotion",
      "state": "calm",
      "energy": 0.65,
      "epoch": 1
    }
    ```
  - **轮次结算完成 (Turn Complete)**：
    ```json
    {
      "type": "turn_complete",
      "user_text": "记一笔午饭三十五元",
      "assistant_text": "好的，已为你记下35元午饭，分类为餐饮外卖。",
      "epoch": 1
    }
    ```

---

### 3.3 代际隔离机制 (Generation Epoch Fencing Architecture)

#### 3.3.1 核心问题定义
在全双工低延迟通话中，音频帧与控制信令并发传输。当用户打断 AI 说话时，网络缓冲区与传输队列中往往仍有数个旧轮次的音频帧在途中。若直接继续向播放器送流，客户端会在被打断后突然“回光返照”播出一两个杂碎字词，破坏沉浸感。

#### 3.3.2 形式化设计与工作流
1. **状态初始化**：WebSocket 连接握手成功时，服务端分配会话上下文并设定 `active_epoch = 1`。
2. **打断触发判据**：
   - 条件一：客户端麦克风 RMS 检测到用户发声，上报 `{"type": "interrupt", "epoch": current}`。
   - 条件二：服务端上游模型 VAD 返回 `{"interrupted": true}`。
3. **Epoch 跃迁与栅栏刷新**：
   - 服务端原子操作递增 `active_epoch = active_epoch + 1`。
   - 网关内部发送队列中所有被标记为旧 `epoch` 的排队音频帧被瞬间清空（Drain）。
   - 服务端向客户端下发 `{"type": "interrupted", "epoch": active_epoch}`。
4. **客户端丢弃过滤 (Packet Dropping)**：
   - 客户端收到 `interrupted` 时，将本地播放队列立即清空，并同步递增本地 `accepted_epoch`。
   - 客户端音频接收调度器（Audio Dispatcher）对任何到达的音频或转录事件执行断言：
     $$\text{if } \text{packet.epoch} < \text{accepted\_epoch} \implies \text{Drop Immediately}$$

```
Client                                Gateway                               Upstream Model
  │                                      │                                         │
  │─── Speaking Audio Frame (Epoch 1) ──>│                                         │
  │                                      │─── Model Turn Audio (Epoch 1) ─────────>│
  │<── Downlink Audio Frame (Epoch 1) ───│                                         │
  │                                      │                                         │
  │ [User Speaks: Barge-in!]             │                                         │
  │─── JSON: {"type": "interrupt"} ─────>│                                         │
  │                                      │ [Epoch Fencing: epoch 1 -> 2]           │
  │                                      │ Flush all queued audio frames           │
  │<── JSON: {"type": "interrupted", ────│                                         │
  │           "epoch": 2}                │                                         │
  │                                      │                                         │
  │ [Stale in-flight audio (Epoch 1)] ──>│ (Dropped by Gateway Queue)              │
  │ (Or if reached Client)               │                                         │
  │ [Client drops packet (epoch 1 < 2)]  │                                         │
  ▼                                      ▼                                         ▼
```

---

### 3.4 iOS 端音频管线与硬件 DSP 规范

#### 3.4.1 硬件 AEC 与 AVAudioSession 严密配置
```swift
let session = AVAudioSession.sharedInstance()
try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
try session.setPreferredIOBufferDuration(0.005) // 5ms 超低 I/O 硬件调度
try session.setActive(true)
```
- `mode: .voiceChat` 强制触发 iOS CoreAudio 底层硬件 DSP 的 VoiceProcessingIO 处理单元，提供硬件级声学回声消除（AEC），杜绝扬声器播音反弹录入。

#### 3.4.2 软衰减即时响应 (Soft Ducking on Voice Activity)
- 客户端在检测到用户瞬时发声（连续 60ms RMS 超过动态自适应背景噪声音阶）的瞬间，**不粗暴硬切播放器**（防止扬声器线圈突变爆音）：
  - 启动 30ms 线性衰减将 `playerNode.volume` 从 1.0 压至 0.15。
  - 向服务端并发上报 `interrupt` 信令。
  - 收到确认或持续发声时执行全静音硬截断并丢弃旧 Epoch 缓冲。

---

## 4. 第三部分：Personal Agent 业务能力融合与闭环持久化

### 4.1 实时流式 Tool Calling 规范与避坑要点

#### (1) ezBookkeeping 秒级时间戳硬纪律
- **致命陷阱**：ezBookkeeping 官方服务仅接受 **Unix Timestamp in SECONDS（秒级整型）**。传毫秒时间戳会导致交易日期被错误记录在公元 58000 年。
- **规范代码**：
  ```python
  now_seconds = int(time.time())
  headers = {
      "X-Timezone-Name": "Asia/Shanghai",
      "X-Timezone-Offset": "480",
  }
  ```

#### (2) 提醒事项微信与日历双写规范
- Eddie 的标准偏好：所有语音安排的提醒事项必须同时写入 `reminders_sync`（供微信机器人通知）与 macOS 系统日历 `Apple Calendar`（以 `【提醒】` 或 `【日程】` 为前缀，提前 5 分钟响铃）。

#### (3) 工具执行反馈流控
- 在工具执行耗时超过 400ms 时，网关必须持续向客户端发送 `{"type": "tool_call", "status": "executing"}`，使 iOS 顶部的状态胶囊保持微动，消除用户由于音频静默产生的断线焦虑。

---

### 4.2 分层记忆架构与实时语音递进注入

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. 会话建立层 (Session Init Profile)                            │
│    - 提取 Eddie 稳定本体画像 (00-核心身份: 称呼/口语风格/作息)   │
│    - 今日核心态势 (今日头条待办 + 关键会议日程)                  │
│    - 严格控制 Token 预算: ≤ 500 Tokens                          │
└────────────────────────────────┬────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. 动态预检索层 (Speculative Just-in-Time Pre-retrieval)         │
│    - 流式 ASR 识别出具名实体（如“首钢攀岩馆”、“梦雨”、“Syncthing”）│
│    - 异步后台并发执行 MemoryCatalog 关键词快搜 (耗时 <20ms)      │
│    - 召回段落即时挂载入模型对话上下文动态槽位                    │
└────────────────────────────────┬────────────────────────────────┘
                                 │
                                 ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. 显式工具查询层 (Explicit `memory_search` Tool Call)          │
│    - 模型在需要准确历史细节时显式发起查询                        │
│    - 调取 memvec.py (1152维向量) + Hindsight 语义匹配           │
└─────────────────────────────────────────────────────────────────┘
```

---

### 4.3 通话结束全自动结构化提炼与多目标落盘

#### 4.3.1 生命周期触发机制
当客户端主动触发 `{"type": "end"}`、点击挂断或 WebSocket 长连接断开时，网关立即激活后台异步任务 `PostCallSummarizer`，绝不阻塞主网关资源释放。

#### 4.3.2 结构化提炼输出 Schema
- **Markdown 报告路径**：`work/工具与效率/会话工作台/records/YYYY-MM/YYYYMMDD_HHMMSS_call_summary.md`
- **JSON 状态归档路径**：`work/工具与效率/会话工作台/records/YYYY-MM/YYYYMMDD_HHMMSS_call_summary.json`
- **Obsidian 任务卡分流**：若包含明确代办，生成 `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/obsidian/任务/待处理/<名称>.md`。
- **Com 记忆库沉淀**：置信度 $\ge 0.8$ 且带用户原话 quote 的新事实写入 `_global/记忆库/Com/mem_<hex>.md`。

---

## 5. 第四部分：特色交互、多模态情绪感知与副通道附和

### 5.1 多模态 5 维情绪感知与声学特征自适应

系统定义 5 维情绪基准并建立映射：
1. **平稳专注 (`calm`)**：基准语调，标准利落回答。
2. **疲惫低落 (`exhausted`)**：放慢语速，语音温和简短，一句话收尾。
3. **焦急紧迫 (`urgent`)**：去除所有寒暄修饰，直截了当口播核心结论与数字。
4. **愉悦兴奋 (`excited`)**：语调上扬轻快，带自然的默契调侃。
5. **关切沉思 (`thoughtful`)**：在分析复杂方案或排障时展现专注专业度。

---

### 5.2 iOS LiveVoiceOrb 流体圆球色温动效联动

基于 SwiftUI `TimelineView` + `Canvas` 实现的有机三叶谐波气泡：
- **`calm`**：Com 标志性青绿亮色（`#D1F061`）。
- **`exhausted`**：暖琥珀与柔夕阳橙（Amber `#F59E0B`）。
- **`urgent`**：鲜亮金黄配合高频微振波纹（`#EAB308`）。
- **`excited`**：翠绿与电光蓝渐变交叠（`#10B981`）。
- **`thoughtful`**：深邃蓝绿（`#06B6D4`）。

---

### 5.3 副通道拟人化倾听附和 (Backchanneling) 与毫秒级熔断

- **判定时机**：用户连续发言超过 4 秒，并在句子中间出现 **600ms – 900ms 的非终结性平缓停顿**。
- **轻拟人声插入**：网关或端侧以 50% 音量轻微插入一段 300–400ms 的微语气声（“嗯”、“在听”），保持人机默契感。
- **即时熔断机制**：只要用户再次发声，拟人声音频在 10ms 内极速淡出切除，绝不抢占用户话语权。

---

## 6. 第五部分：后端网关适配器架构与代际隔离实现规划

### 6.1 `LiveUpstreamAdapter` 接口抽象体系

为消除单一模型绑定的技术债务，网关服务层抽象出标准化的异步上游适配器：

```python
from abc import ABC, abstractmethod
from typing import AsyncIterator, Any

class LiveUpstreamAdapter(ABC):
    """Abstract Base Class for full-duplex realtime speech-to-speech upstream engines."""

    @abstractmethod
    async def connect(self, voice: str, system_prompt: str, tools: list[dict[str, Any]]) -> None:
        """Establish full-duplex session with upstream model."""

    @abstractmethod
    async def send_audio(self, pcm_16k: bytes) -> None:
        """Stream 16kHz linear PCM audio chunks (100ms / 3200 bytes) upstream."""

    @abstractmethod
    async def send_text_turn(self, text: str) -> None:
        """Send explicit text input into the ongoing conversation."""

    @abstractmethod
    async def send_tool_response(self, call_id: str, name: str, output: dict[str, Any]) -> None:
        """Return execution result of a function call to the model."""

    @abstractmethod
    async def interrupt(self) -> None:
        """Notify upstream of client-side barge-in interruption."""

    @abstractmethod
    def incoming_events(self) -> AsyncIterator[dict[str, Any]]:
        """Asynchronously yield normalized events from upstream.
        Normalized events include:
          - {"type": "audio", "data": bytes (24kHz PCM)}
          - {"type": "transcript", "role": "user"|"assistant", "text": str, "finished": bool}
          - {"type": "tool_call", "calls": list[dict]}
          - {"type": "interrupted"}
          - {"type": "turn_complete"}
          - {"type": "emotion", "state": str, "energy": float}
        """

    @abstractmethod
    async def close(self) -> None:
        """Gracefully terminate upstream session."""
```

---

### 6.2 适配器实现阵列

1. **`GeminiLiveAdapter`**：
   - 适配 Google Cloud Vertex AI `LlmBidiService/BidiGenerateContent`。
   - 自动获取 OAuth 令牌，支持主备 GCP 开发者项目故障隔离。
   - 双向 16kHz 转码入与 24kHz Base64 解码出。
   - 转换 Google 原始 `serverContent` 为标准化事件结构。
2. **`OpenAIRealtimeAdapter`**：
   - 适配 `wss://api.openai.com/v1/realtime`。
   - 负责 session.update 配置与 JSON 载荷封装，实现模型无缝替换与容灾回退。
3. **`MockLiveAdapter` (高可靠全流控测试专用引擎)**：
   - 100% 确定性、脱机离线、无外部网络依赖。
   - 模拟音频双向流（自动生成 24kHz 测试正弦波或回声包）、打断响应、实时双向转写字幕下发、情绪信令与工具调用握手。
   - 支持通过参数注入模拟网络延迟与打断测试场景，为本地单元测试与 CI/CD 提供确定性保障。

---

### 6.3 测试与验证基线

- **自动化测试规范**：测试代码必须位于 `backend/tests/test_voice_live.py`。
- **必须覆盖场景**：
  1. 上游适配器无缝切换能力（`upstream_factory` 支持 `GeminiLiveAdapter` 与 `MockLiveAdapter`）。
  2. 全双工会话握手、双向音频帧收发与双向字幕流交付。
  3. **代际隔离防串流测试**：打断触发后旧 Epoch 音频帧被确实验证丢弃，新 Epoch 正常流转。
  4. 实时工具调用闭环：模型触发 `tool_call` -> 网关执行 -> 结果回传模型 -> 口播跟进完成。
- **通过准则**：所有用例必须通过 `pytest` 执行且通过率达到 100%。

---
*本白皮书由 Teamwork Voice Taskforce 编纂并归档至 `work/工具与效率/会话工作台/docs/AI_REALTIME_VOICE_RESEARCH.md`，作为后续客户端、后端及端到端自动化测试的唯一权威参考指南。*

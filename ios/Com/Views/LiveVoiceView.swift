import SwiftUI
import ComCore

/// 实时语音通话页：暗场 + 一颗青柠圆球 + 向上滚动的对话字幕 + 三个大按键。
struct LiveVoiceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduce

    private var session: LiveVoiceSession { model.liveVoice }
    private var isReconnecting: Bool { session.phase.rawValue == "reconnecting" }

    /// 圆球下方的一行短词；Com 在说话时留白。
    private var statusWord: String {
        if isReconnecting { return "信号不好，正在重连" }
        switch session.phase {
        case .connecting: return "正在接通"
        case .listening: return session.muted ? "已静音" : "在听"
        case .thinking: return session.activeToolTitle.isEmpty ? "在想" : session.activeToolTitle
        case .speaking: return session.activeToolTitle
        case .failed: return "断开了，点圆球重试"
        default: return ""
        }
    }

    private var haloColor: Color {
        session.phase == .failed ? Palette.coral : Palette.accent
    }

    private var haloStrength: Double {
        switch session.phase {
        case .speaking: return 0.10 + session.assistantLevel * 0.16
        case .listening: return session.muted ? 0.03 : 0.05 + session.userLevel * 0.08
        case .failed: return 0.06
        default: return 0.07
        }
    }

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.043, blue: 0.035).ignoresSafeArea()

            // 圆球身后的环境光，跟着音量轻微起伏
            RadialGradient(
                colors: [haloColor.opacity(haloStrength), haloColor.opacity(haloStrength * 0.25), .clear],
                center: UnitPoint(x: 0.5, y: 0.36),
                startRadius: 30,
                endRadius: 420
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, Layout.margin)
                    .padding(.top, Space.md)

                Spacer(minLength: Space.md)

                LiveVoiceOrb(
                    phase: session.phase,
                    userLevel: session.userLevel,
                    assistantLevel: session.assistantLevel,
                    muted: session.muted,
                    bargeInTriggerCount: session.bargeInTriggerCount
                )
                .frame(width: 300, height: 300)
                .contentShape(Circle().inset(by: 50))
                .onTapGesture {
                    if session.phase == .speaking {
                        Haptics.sent()
                        session.interruptPlayback(sendInterruptSignal: true)
                    } else if session.phase == .failed {
                        Haptics.selection()
                        Task { await session.start(using: model.client, uiTesting: model.isUITesting) }
                    }
                }
                .accessibilityIdentifier("live-voice-orb")
                .accessibilityLabel("Com，轻触可打断或重连")

                statusLine
                    .padding(.top, -Space.xl)

                Spacer(minLength: Space.md)

                captions
                    .padding(.horizontal, Layout.margin + Space.md)
                    .padding(.bottom, Space.xxl)

                bottomControls
                    .padding(.bottom, Space.xxl)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            session.onTurnComplete = nil
            if session.phase == .idle {
                await session.start(using: model.client, uiTesting: model.isUITesting)
            }
        }
        .onDisappear {
            session.stop()
            Task { await model.refresh(.chat) }
        }
    }

    // MARK: 顶栏

    private var topBar: some View {
        HStack(spacing: Space.sm) {
            HStack(spacing: 7) {
                Circle()
                    .fill(session.phase == .failed ? Palette.coral : Palette.accent)
                    .frame(width: 6, height: 6)
                    .opacity(session.phase == .connecting || isReconnecting ? 0.4 : 1)
                Text(String(format: "%d:%02d", session.seconds / 60, session.seconds % 60))
                    .font(TypeScale.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.62))
                    .contentTransition(.numericText())
            }
            .padding(.leading, Space.xs)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("通话时长")
            .accessibilityIdentifier("live-voice-status-pill")

            Spacer()

            Button {
                session.showSubtitles.toggle()
                Haptics.selection()
            } label: {
                Image(systemName: session.showSubtitles ? "captions.bubble.fill" : "captions.bubble")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white.opacity(session.showSubtitles ? 0.9 : 0.45))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.07), in: Circle())
            }
            .buttonStyle(SoftPressStyle(scale: 0.92))
            .accessibilityLabel(session.showSubtitles ? "隐藏字幕" : "显示字幕")
            .accessibilityIdentifier("live-voice-subtitle-toggle")

            Menu {
                Picker("音色", selection: Binding(
                    get: { session.voiceName },
                    set: { new in Task { await session.switchVoice(new, using: model.client, uiTesting: model.isUITesting) } }
                )) {
                    ForEach(LiveVoiceOption.all) { opt in
                        Text("\(opt.label) · \(opt.subtitle)").tag(opt.id)
                    }
                }
            } label: {
                Image(systemName: "person.wave.2")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.07), in: Circle())
            }
            .accessibilityLabel("切换音色，当前 \(session.voiceName)")
            .accessibilityIdentifier("live-voice-picker")
        }
    }

    // MARK: 状态短词

    private var statusLine: some View {
        HStack(spacing: 6) {
            if session.phase == .thinking || session.phase == .connecting || isReconnecting {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.white.opacity(0.5))
            }
            Text(statusWord)
                .font(TypeScale.footnote.weight(.medium))
                .foregroundStyle(session.phase == .failed ? Palette.coral : .white.opacity(0.46))
                .contentTransition(.opacity)
        }
        .frame(height: 20)
        .animation(ComMotion.reduced(reduce, ComMotion.crossfade), value: statusWord)
        .accessibilityIdentifier("live-voice-status-text")
    }

    // MARK: 字幕：最近几句自下而上，最新一句最亮，往上渐隐

    @ViewBuilder
    private var captions: some View {
        let recent = Array(session.lines.suffix(3))
        VStack(spacing: Space.md) {
            if !session.error.isEmpty {
                Text(session.error)
                    .font(TypeScale.callout)
                    .foregroundStyle(Palette.coral.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("live-voice-error")
            } else if session.showSubtitles {
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, line in
                    let isLatest = index == recent.count - 1
                    Text(line.text)
                        .font(line.isUser
                              ? TypeScale.callout
                              : .system(isLatest ? .title3 : .callout, design: .rounded, weight: isLatest ? .semibold : .regular))
                        .foregroundStyle(line.isUser
                                         ? Palette.accent.opacity(isLatest ? 0.78 : 0.34)
                                         : Color.white.opacity(isLatest ? 0.94 : 0.34))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .lineLimit(isLatest ? 4 : 2)
                        .truncationMode(.head)
                        .frame(maxWidth: 520)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 14)),
                            removal: .opacity.combined(with: .offset(y: -10))))
                        .accessibilityIdentifier(line.isUser ? "live-voice-user-transcript" : "live-voice-assistant-transcript")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 168, alignment: .bottom)
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.28)],
                             startPoint: .top, endPoint: .bottom))
        .animation(ComMotion.reduced(reduce, ComMotion.settle), value: recent.map(\.id))
    }

    // MARK: 底部三键

    private var bottomControls: some View {
        HStack(spacing: 36) {
            callButton(
                icon: session.muted ? "mic.slash.fill" : "mic.fill",
                on: session.muted,
                label: session.muted ? "取消静音" : "静音",
                id: "live-voice-mute"
            ) {
                session.muted.toggle()
                Haptics.selection()
            }

            callButton(
                icon: session.speakerOn ? "speaker.wave.2.fill" : "ear",
                on: !session.speakerOn,
                label: session.speakerOn ? "切到听筒" : "切到扬声器",
                id: "live-voice-speaker"
            ) {
                session.speakerOn.toggle()
                Haptics.selection()
            }

            Button {
                Haptics.sent()
                session.stop()
                model.showLiveVoice = false
                Task { await model.refresh(.chat) }
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 88, height: 68)
                    .background(Color(red: 0.92, green: 0.26, blue: 0.22), in: Capsule())
            }
            .buttonStyle(SoftPressStyle(scale: 0.93))
            .accessibilityLabel("挂断")
            .accessibilityIdentifier("live-voice-hangup")
        }
    }

    private func callButton(icon: String, on: Bool, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(on ? Color.black : Color.white)
                .frame(width: 68, height: 68)
                .background(on ? Color.white.opacity(0.92) : Color.white.opacity(0.10), in: Circle())
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(SoftPressStyle(scale: 0.92))
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

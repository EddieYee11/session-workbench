import SwiftUI
import ComCore

struct PairView: View {
    @Environment(HeaderModel.self) private var backend
    @Environment(HerdrSessionStore.self) private var store
    @State private var serverAddress = ""
    @State private var code = ""
    @State private var errorMessage = ""
    @State private var isSubmitting = false

    var body: some View {
        NavigationStack {
            ScrollPage(spacing: Space.xl) {
                VStack(spacing: Space.md) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Palette.accentText)
                        .padding(.top, Space.lg)

                    Text("Herdr 终端")
                        .font(TypeScale.title)
                        .foregroundStyle(Palette.textPrimary)

                    Text("直连 Mac mini 与 MBP，极速控制台")
                        .font(TypeScale.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, Space.md)

                VStack(alignment: .leading, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("后端地址")
                            .font(TypeScale.caption)
                            .foregroundStyle(Palette.textSecondary)
                        TextField("https://...", text: $serverAddress)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(Space.md)
                            .background(Palette.fill, in: .rect(cornerRadius: Radius.md))
                    }

                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("一次性配对码")
                            .font(TypeScale.caption)
                            .foregroundStyle(Palette.textSecondary)
                        HStack {
                            TextField("6 位配对码", text: $code)
                                .font(.system(.body, design: .monospaced))
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.characters)
                                .padding(Space.md)

                            if let clip = UIPasteboard.general.string, !clip.isEmpty, clip.count <= 12 {
                                Button("粘贴") {
                                    code = clip.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                                .font(TypeScale.caption)
                                .padding(.trailing, Space.md)
                            }
                        }
                        .background(Palette.fill, in: .rect(cornerRadius: Radius.md))
                    }

                    if !errorMessage.isEmpty {
                        InlineNotice(text: errorMessage, tone: .danger)
                    }

                    Button {
                        submitPair()
                    } label: {
                        if isSubmitting {
                            ProgressView()
                                .tint(Palette.onAccent)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("立即配对")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.primaryFull)
                    .disabled(isSubmitting || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Text("在 Com 设置中生成配对码，或使用深链 herdr-eddie://pair?base=&code= 自动配对。")
                        .font(TypeScale.footnote)
                        .foregroundStyle(Palette.textTertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Space.sm)
                }
                .padding(.horizontal, Space.lg)
            }
            .navigationTitle("设备配对")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                serverAddress = backend.base
            }
        }
    }

    private func submitPair() {
        guard !isSubmitting else { return }
        errorMessage = ""
        isSubmitting = true
        backend.base = serverAddress.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                try await backend.pair(code: code)
                await store.prepare(backend: backend)
                isSubmitting = false
            } catch {
                isSubmitting = false
                errorMessage = error.localizedDescription
            }
        }
    }
}

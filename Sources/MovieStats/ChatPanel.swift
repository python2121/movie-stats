import MarkdownUI
import SwiftUI

/// The right-side "Ask Claude" panel. Renders the chat transcript, the
/// inline status line while streaming, and the input row at the bottom. Falls
/// back to a helper message when Claude Code isn't installed.
struct ChatPanel: View {
    @Bindable var model: ChatModel
    let onClose: () -> Void

    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.hasClaudeCode {
                transcript
                Divider()
                inputRow
            } else {
                Spacer()
                missingClaudeCode
                Spacer()
            }
        }
        .frame(maxHeight: .infinity)
        .background(.windowBackground)
        .onAppear {
            // Brief delay gives the panel's slide-in animation a moment to
            // settle before SwiftUI accepts the focus assignment.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                inputFocused = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            Text("Query the AI God")
                .font(.headline)
            Spacer()
            if !model.messages.isEmpty {
                Button {
                    model.clear()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Clear conversation")
            }
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if model.messages.isEmpty {
                        emptyState
                    }
                    ForEach(model.messages) { message in
                        bubble(for: message)
                            .id(message.id)
                    }
                    if let status = model.statusLine {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.tail)
                        }
                        .padding(.horizontal, 12)
                        .id("status")
                    }
                }
                .padding(.vertical, 14)
            }
            .onChange(of: model.messages.count) { _, _ in
                if let id = model.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: model.statusLine) { _, status in
                guard status != nil else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("status", anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask anything about your library.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Try:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Text("• What's my biggest 4K UHD Remux?")
                Text("• How much disk does Dolby Vision content take?")
                Text("• Which movies don't have English audio?")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
    }

    @ViewBuilder
    private func bubble(for message: ChatModel.Message) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 24)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
            }
            .padding(.horizontal, 12)
        case .assistant:
            Markdown(message.text)
                .markdownTheme(.chatTheme)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .system:
            Label(message.text, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.horizontal, 14)
        }
    }

    // MARK: - Missing CLI fallback

    private var missingClaudeCode: some View {
        VStack(spacing: 10) {
            Image(systemName: "terminal")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Claude Code isn't installed")
                .font(.headline)
            Text("This panel shells out to the `claude` CLI to answer questions about your library, billed against your Claude.ai subscription.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Link("Install Claude Code", destination: URL(string: "https://www.claude.com/product/claude-code")!)
                .font(.callout)
        }
        .padding(20)
        .frame(maxWidth: 320)
    }

    // MARK: - Input

    private var inputRow: some View {
        HStack(spacing: 8) {
            TextField("Ask about your library…", text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                .focused($inputFocused)
                .onSubmit { model.send() }
                .disabled(model.isStreaming)

            if model.isStreaming {
                Button {
                    model.cancel()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .help("Stop")
            } else {
                Button {
                    model.send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .imageScale(.large)
                }
                .buttonStyle(.borderless)
                .disabled(!model.canSend)
                .keyboardShortcut(.return)
                .help("Send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

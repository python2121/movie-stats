import SwiftUI

/// "IMDb Ratings" window. Single workflow: hit Refresh, watch the status
/// line tick through download → decompress → parse → import, end with a
/// completed state showing the new entry count. Designed to be small —
/// no table, just a status block + one button.
struct IMDbView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var imdb: IMDbModel?

    var body: some View {
        Group {
            if let imdb {
                content(model: imdb)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, minHeight: 320)
        .onAppear {
            if imdb == nil {
                imdb = IMDbModel(appModel: appModel)
            } else {
                imdb?.loadMetadata()
            }
        }
        .onExitCommand { dismiss() }
        .background {
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private func content(model: IMDbModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            statusBlock(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer(model: model)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("IMDb Ratings")
                .font(.headline)
            Text("Pulls the IMDb-published `title.ratings.tsv.gz` bulk dataset and indexes it locally.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func statusBlock(model: IMDbModel) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Persisted state at top — survives across runs.
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Last downloaded:")
                        .foregroundStyle(.secondary)
                    Text(lastDownloadedText(model: model))
                        .font(.body.monospacedDigit())
                        .textSelection(.enabled)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Ratings on file:")
                        .foregroundStyle(.secondary)
                    Text(model.entryCount > 0
                         ? NumberFormatter.localizedString(from: NSNumber(value: model.entryCount), number: .decimal)
                         : "—")
                        .font(.body.monospacedDigit())
                        .textSelection(.enabled)
                }
            }

            Divider()

            // Live state during a refresh.
            currentStateRow(model: model)
                .font(.callout)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func currentStateRow(model: IMDbModel) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch model.state {
            case .idle:
                Image(systemName: "circle.dotted")
                    .foregroundStyle(.secondary)
                Text(model.hasData ? "Ready. Refresh anytime to pull the latest." : "No data yet — click Refresh to download.")
                    .foregroundStyle(.secondary)

            case .downloading:
                ProgressView().controlSize(.small)
                Text("Downloading `title.ratings.tsv.gz`…")

            case .decompressing:
                ProgressView().controlSize(.small)
                Text("Decompressing…")

            case .parsing:
                ProgressView().controlSize(.small)
                Text("Parsing TSV…")

            case .importing(let count):
                ProgressView().controlSize(.small)
                Text("Importing \(NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)) ratings…")

            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Done.")
                    .foregroundStyle(.primary)

            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .foregroundStyle(.red)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func footer(model: IMDbModel) -> some View {
        HStack {
            Text(IMDbDatasetService.ratingsURL.absoluteString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(model.hasData ? "Refresh" : "Download") {
                Task { await model.refresh() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.isWorking)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Formatting

    private func lastDownloadedText(model: IMDbModel) -> String {
        guard let date = model.lastDownloadedAt else { return "Never" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

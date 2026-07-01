import Charts
import SwiftUI

/// Deeper library analytics than the main window's two donuts: decade and
/// genre distributions, watch progress, and headline totals. Everything is
/// computed live from the in-memory movie list.
struct InsightsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statCards

                HStack(alignment: .top, spacing: 16) {
                    chartCard("Movies by decade") { decadeChart }
                    chartCard("Top genres") { genreChart }
                }
                .frame(height: 280)

                HStack(alignment: .top, spacing: 16) {
                    chartCard("IMDb rating distribution") { ratingChart }
                    chartCard("Watch progress by type") { watchedChart }
                }
                .frame(height: 280)

                chartCard("Library growth") { growthChart }
                    .frame(height: 240)
            }
            .padding(24)
        }
        .frame(minWidth: 860, minHeight: 600)
        .navigationTitle("Insights")
        .onExitCommand { dismiss() }
        .background(
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        )
    }

    // MARK: - Headline stats

    private var statCards: some View {
        HStack(spacing: 12) {
            statCard("Total Runtime", totalRuntimeText, "clock")
            statCard("Watched", watchedText, "checkmark.circle")
            statCard("Average IMDb", averageIMDbText, "star")
            statCard("Matched", matchedText, "popcorn")
            statCard("Average Size", averageSizeText, "internaldrive")
        }
        .frame(height: 64)
    }

    private func statCard(_ title: String, _ value: String, _ icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(.body, design: .rounded).weight(.semibold))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    private var totalRuntimeText: String {
        let minutes = appModel.movies.compactMap(\.runtimeMinutes).reduce(0, +)
        guard minutes > 0 else { return "—" }
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        return "\(hours)h \(minutes % 60)m"
    }

    private var watchedText: String {
        let total = appModel.movies.count
        guard total > 0 else { return "—" }
        let watched = appModel.movies.filter { $0.watchedAt != nil }.count
        return "\(watched) of \(total)"
    }

    private var averageIMDbText: String {
        let ratings = appModel.movies.compactMap(\.imdbRating)
        guard !ratings.isEmpty else { return "—" }
        return String(format: "%.1f", ratings.reduce(0, +) / Double(ratings.count))
    }

    private var matchedText: String {
        let total = appModel.movies.count
        guard total > 0 else { return "—" }
        let matched = appModel.movies.filter { $0.tmdbId != nil }.count
        return "\(matched * 100 / total)%"
    }

    private var averageSizeText: String {
        let total = appModel.movies.count
        guard total > 0 else { return "—" }
        let bytes = appModel.movies.reduce(Int64(0)) { $0 + $1.size } / Int64(total)
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Charts

    private func chartCard(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private struct CountBucket: Identifiable {
        let label: String
        let count: Int
        var id: String { label }
    }

    private var decadeBuckets: [CountBucket] {
        let grouped = Dictionary(grouping: appModel.movies.compactMap { movie in
            movie.effectiveYear.map { ($0 / 10) * 10 }
        }, by: { $0 })
        return grouped
            .sorted { $0.key < $1.key }
            .map { CountBucket(label: "\(String($0.key))s", count: $0.value.count) }
    }

    private var decadeChart: some View {
        Chart(decadeBuckets) { bucket in
            BarMark(
                x: .value("Decade", bucket.label),
                y: .value("Movies", bucket.count)
            )
            .foregroundStyle(.blue.gradient)
            .annotation(position: .top, alignment: .center) {
                Text("\(bucket.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var genreBuckets: [CountBucket] {
        let grouped = Dictionary(grouping: appModel.movies.flatMap(\.genres), by: { $0 })
        return grouped
            .map { CountBucket(label: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
            .prefix(10)
            .map { $0 }
    }

    private var genreChart: some View {
        Chart(genreBuckets) { bucket in
            BarMark(
                x: .value("Movies", bucket.count),
                y: .value("Genre", bucket.label)
            )
            .foregroundStyle(.teal.gradient)
            .annotation(position: .trailing) {
                Text("\(bucket.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks { mark in
                AxisValueLabel()
            }
        }
    }

    private var ratingBuckets: [CountBucket] {
        let grouped = Dictionary(grouping: appModel.movies.compactMap(\.imdbRating)) { rating in
            Int(rating.rounded(.down))
        }
        return (1...10).map { score in
            CountBucket(label: "\(score)", count: grouped[score]?.count ?? 0)
        }
    }

    private var ratingChart: some View {
        Chart(ratingBuckets) { bucket in
            BarMark(
                x: .value("Rating", bucket.label),
                y: .value("Movies", bucket.count)
            )
            .foregroundStyle(.yellow.gradient)
        }
        .chartXAxisLabel("IMDb rating, rounded down")
    }

    private struct GrowthPoint: Identifiable {
        let month: Date
        let cumulative: Int
        var id: Date { month }
    }

    /// Cumulative library count over time, bucketed by the month each file
    /// was first seen. Rows predating the `first_seen_at` column all carry
    /// the same backfill timestamp, so old libraries start with one big
    /// jump — accurate from that point forward.
    private var growthPoints: [GrowthPoint] {
        let calendar = Calendar.current
        let months = appModel.movies.compactMap { movie in
            movie.firstSeenAt.flatMap {
                calendar.date(from: calendar.dateComponents([.year, .month], from: $0))
            }
        }
        var running = 0
        return Dictionary(grouping: months, by: { $0 })
            .sorted { $0.key < $1.key }
            .map { month, added in
                running += added.count
                return GrowthPoint(month: month, cumulative: running)
            }
    }

    @ViewBuilder
    private var growthChart: some View {
        if growthPoints.isEmpty {
            Text("No data yet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            Chart(growthPoints) { point in
                AreaMark(
                    x: .value("Month", point.month, unit: .month),
                    y: .value("Movies", point.cumulative)
                )
                .foregroundStyle(.blue.opacity(0.15))
                LineMark(
                    x: .value("Month", point.month, unit: .month),
                    y: .value("Movies", point.cumulative)
                )
                .foregroundStyle(.blue)
            }
        }
    }

    private struct WatchedBucket: Identifiable {
        let type: String
        let status: String
        let count: Int
        var id: String { "\(type)-\(status)" }
    }

    private var watchedBuckets: [WatchedBucket] {
        let byType = Dictionary(grouping: appModel.movies) { $0.movieType ?? "Unprobed" }
        return byType.flatMap { type, movies -> [WatchedBucket] in
            let watched = movies.filter { $0.watchedAt != nil }.count
            return [
                WatchedBucket(type: type, status: "Watched", count: watched),
                WatchedBucket(type: type, status: "Unwatched", count: movies.count - watched),
            ]
        }
        .filter { $0.count > 0 }
    }

    private var watchedChart: some View {
        Chart(watchedBuckets) { bucket in
            BarMark(
                x: .value("Movies", bucket.count),
                y: .value("Type", bucket.type)
            )
            .foregroundStyle(by: .value("Status", bucket.status))
        }
        .chartForegroundStyleScale([
            "Watched": Color.green.opacity(0.8),
            "Unwatched": Color.gray.opacity(0.45),
        ])
    }
}

import SwiftUI
import WidgetKit

private struct LauncherEntry: TimelineEntry {
    let date: Date
}

private struct LauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> LauncherEntry {
        LauncherEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (LauncherEntry) -> Void) {
        completion(LauncherEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LauncherEntry>) -> Void) {
        completion(Timeline(entries: [LauncherEntry(date: .now)], policy: .never))
    }
}

private struct PaceCoachMark: View {
    let compact: Bool

    @Environment(\.widgetRenderingMode) private var renderingMode

    @ViewBuilder
    private var artwork: some View {
        if renderingMode == .fullColor {
            Image("PaceCoachComplicationColor")
                .resizable()
                .interpolation(.high)
        } else {
            Image("PaceCoachComplicationMono")
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .foregroundStyle(.primary)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)

            artwork
                .aspectRatio(contentMode: .fit)
                .frame(width: side * (compact ? 0.92 : 0.98),
                       height: side * (compact ? 0.92 : 0.98))
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityLabel("Open PaceCoach")
    }
}

private struct LauncherComplicationView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        PaceCoachMark(compact: family == .accessoryCorner)
            .containerBackground(.clear, for: .widget)
    }
}

@main
struct PaceCoachLauncherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PaceCoachLauncher", provider: LauncherProvider()) { _ in
            LauncherComplicationView()
        }
        .configurationDisplayName("PaceCoach")
        .description("Open PaceCoach on your Apple Watch")
        .supportedFamilies([.accessoryCircular, .accessoryCorner])
    }
}

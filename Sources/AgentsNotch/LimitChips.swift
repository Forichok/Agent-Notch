import SwiftUI
import NotchCore

struct LimitChips: View {
    @ObservedObject var usage: UsageModel
    @EnvironmentObject private var settings: AppSettings
    var mode: LimitChipMode? = nil

    var body: some View {
        HStack(spacing: 4) {
            ForEach(usage.limits, id: \.vendor) { limits in
                if let limits = settings.displayedLimits(limits),
                   (mode ?? settings.appearance.limitChips).isVisible(usedPercent: UsageView.tightest(limits),
                       threshold: Double(settings.limits.warningPercent)) {
                    Button { usage.selectLimits(limits.vendor) } label: {
                        Text(UsageViewText.chip(limits))
                            .foregroundStyle(UsageView.limitTone(UsageView.tightest(limits) ?? 0, warningPercent: Double(settings.limits.warningPercent)).usageColor)
                    }
                    .buttonStyle(Pill(primary: false))
                    .help(limits.windows.isEmpty ? UsageViewText.stale :
                        limits.windows.map { UsageViewText.window($0, now: usage.now) }.joined(separator: "\n"))
                }
            }
        }
        .fixedSize()
        .background(UsageListVisibility(usage: usage).frame(width: 0, height: 0))
    }
}

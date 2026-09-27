import Foundation
@_exported import AgentContract

extension LimitWindow {
    public var title: String {
        guard let minutes = durationMinutes else { return id == "primary" ? L10n.text("Основной лимит", "Primary limit") : L10n.text("Дополнительный лимит", "Additional limit") }
        if minutes % 1440 == 0 { return L10n.text("За \(minutes / 1440) д.", "\(minutes / 1440)-day window") }
        if minutes % 60 == 0 { return L10n.text("За \(minutes / 60) ч.", "\(minutes / 60)-hour window") }
        if minutes < 60 { return L10n.text("За \(minutes) мин.", "\(minutes)-minute window") }
        return L10n.text("За \(minutes / 60) ч. \(minutes % 60) мин.", "\(minutes / 60) hr \(minutes % 60) min window")
    }
}

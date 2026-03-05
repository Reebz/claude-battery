import Foundation

enum IconStyle: String, CaseIterable {
    case dualHorizontal = "Dual Horizontal"
    case minimal        = "Minimal"
    case dualArcGauge   = "Dual Arc Gauge"
    case textOnly       = "Text Only"
    case stackedBars    = "Stacked Bars"

    var renderer: IconRenderer {
        switch self {
        case .dualHorizontal: DualHorizontalRenderer()
        case .minimal:        MinimalRenderer()
        case .dualArcGauge:   DualArcGaugeRenderer()
        case .textOnly:       TextOnlyRenderer()
        case .stackedBars:    StackedBarsRenderer()
        }
    }
}

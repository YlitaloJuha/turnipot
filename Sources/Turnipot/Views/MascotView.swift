import SwiftUI
import AppKit
import NotchCore

/// The island's pixel mascot: the turnip in its pot (TurnipView.swift), compact layout (16 rows =
/// the 32pt strip at 2pt pixels: pot on the strip's bottom rows, turnip above). Smaller pixels if
/// the strip is shorter (no-notch screens); centred vertically when it has room (expanded bar).
struct MascotView: View {
    let mood: MascotMood
    var pixelSize: CGFloat = 2.5
    /// Show the drifting "z" while sleeping.
    var showZ: Bool = true
    /// Play the watering (usage reset).
    var watering: Bool = false

    @Environment(\.mascotStripHeight) private var stripHeight

    /// Mascot pixel size for a notch strip of the given height: 2pt (4 device px on Retina,
    /// crisp) when the strip is at least 24pt, else 1.5pt; `body` shrinks it further to fit.
    static func pixelSize(forStrip height: CGFloat) -> CGFloat {
        height >= 24 ? 2 : 1.5
    }

    var body: some View {
        let rows = CGFloat(TurnipRig.Layout.compact.rows)
        let p = rows * pixelSize <= stripHeight ? pixelSize : max(1, (stripHeight / rows * 2).rounded(.down) / 2)
        return TurnipMascotView(mood: mood, pixelSize: p, layout: .compact, showZ: showZ, watering: watering)
            .frame(maxHeight: .infinity, alignment: .center)
    }
}

/// Pixel rects -> one path (shared by the Canvas and Core Animation drawing).
enum PixelPath {
    static func path(_ rects: [CGRect], p: CGFloat, dx: CGFloat = 0, dy: CGFloat = 0) -> CGPath {
        let path = CGMutablePath()
        for r in rects {
            path.addRect(CGRect(x: (r.minX + dx) * p, y: (r.minY + dy) * p, width: r.width * p, height: r.height * p))
        }
        return path
    }
}

enum Theme {
    static let accent = Color(hex: 0xd97757)
    static let green  = Color(hex: 0x4ade80)
    static let amber  = Color(hex: 0xfbbf24)
    static let red    = Color(hex: 0xf87171)
    /// Usage ring tones, outermost first: the pot's light rim, the pot, the pot's shadow.
    static let rings: [Color] = [Color(hex: TurnipRig.rimHex), Color(hex: TurnipRig.potHex), Color(hex: TurnipRig.potDarkHex)]
    static func ringColor(_ i: Int) -> Color { rings[min(max(i, 0), rings.count - 1)] }
    static let muted  = Color(hex: 0x8a8a8f)
    static let card   = Color(hex: 0x16161a)
    static let cardBorder = Color(hex: 0x2c2c32)
    static let codeBackground = Color(hex: 0x1c1c20)
    static let rowHover = Color(hex: 0x17171b)
    static let chip   = Color(hex: 0x222222)
    static let barTrack = Color(hex: 0x2a2a2e)
    /// Unseen badge / chip backgrounds (orange "done", amber "waiting").
    static let doneTint = Color(hex: 0x3a2216)
    static let waitingTint = Color(hex: 0x3a2e10)
    /// Unseen session row backgrounds in the expanded panel.
    static let doneRow = Color(hex: 0x1a130f)
    static let waitingRow = Color(hex: 0x1d1708)
    /// Second line (last sentence) of an unseen row.
    static let quote = Color(hex: 0xc9c9ce)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: opacity)
    }
}

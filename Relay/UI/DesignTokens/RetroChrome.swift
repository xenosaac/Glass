import SwiftUI
import UIKit

struct RetroCutShape: InsettableShape {
 var cut: CGFloat = 8
 var insetAmount: CGFloat = 0

 func path(in rect: CGRect) -> Path {
 let insetRect = rect.insetBy(dx: insetAmount, dy: insetAmount)
 let cut = max(3, min(self.cut, min(insetRect.width, insetRect.height) * 0.22))

 var path = Path()
 path.move(to: CGPoint(x: insetRect.minX + cut, y: insetRect.minY))
 path.addLine(to: CGPoint(x: insetRect.maxX - cut, y: insetRect.minY))
 path.addLine(to: CGPoint(x: insetRect.maxX, y: insetRect.minY + cut))
 path.addLine(to: CGPoint(x: insetRect.maxX, y: insetRect.maxY - cut))
 path.addLine(to: CGPoint(x: insetRect.maxX - cut, y: insetRect.maxY))
 path.addLine(to: CGPoint(x: insetRect.minX + cut, y: insetRect.maxY))
 path.addLine(to: CGPoint(x: insetRect.minX, y: insetRect.maxY - cut))
 path.addLine(to: CGPoint(x: insetRect.minX, y: insetRect.minY + cut))
 path.closeSubpath()
 return path
 }

 func inset(by amount: CGFloat) -> some InsettableShape {
 var copy = self
 copy.insetAmount += amount
 return copy
 }
}

enum RetroMetrics {
 static let borderWidth: CGFloat = 2
 static let thinBorderWidth: CGFloat = 1.5
 static let panelCut: CGFloat = 10
 static let pillCut: CGFloat = 8
 static let buttonCut: CGFloat = 9
 static let surfaceLift: CGFloat = 3
 static let buttonLift: CGFloat = 6
 static let pressedLift: CGFloat = 2
 static let iconButtonSize: CGFloat = 42
 static let rowMinHeight: CGFloat = 52
}

struct RetroPalette {
 let fill: Color
 let border: Color
 let highlight: Color
 let shadow: Color
 let foreground: Color
}

struct RetroPixelBlock: View {
 let color: Color
 var size: CGFloat = 6

 var body: some View {
 RetroCutShape(cut: max(1.5, size * 0.22))
 .fill(color)
 .frame(width: size, height: size)
 }
}

extension Color {
 init(hex: UInt32, opacity: Double = 1.0) {
 self.init(
 .sRGB,
 red: Double((hex >> 16) & 0xFF) / 255.0,
 green: Double((hex >> 8) & 0xFF) / 255.0,
 blue: Double(hex & 0xFF) / 255.0,
 opacity: opacity
 )
 }

 init(light: UInt32, dark: UInt32, opacity: Double = 1.0) {
 self.init(uiColor: UIColor { trait in
 let hex = trait.userInterfaceStyle == .dark ? dark : light
 return UIColor(
 red: CGFloat((hex >> 16) & 0xFF) / 255.0,
 green: CGFloat((hex >> 8) & 0xFF) / 255.0,
 blue: CGFloat(hex & 0xFF) / 255.0,
 alpha: opacity
 )
 })
 }
}

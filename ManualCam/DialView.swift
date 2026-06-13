import SwiftUI

// MARK: - Generic Rotary Dial
struct DialView<T: BinaryFloatingPoint>: View {
    let label: String
    let values: [T]
    let format: (T) -> String
    @Binding var selectedIndex: Int
    var isLocked: Bool = false
    var accentColor: Color = .yellow

    @GestureState private var dragOffset: CGFloat = 0
    @State private var baseOffset: CGFloat = 0

    private let tickSpacing: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            // Center indicator line
            Rectangle()
                .fill(isLocked ? Color.gray : accentColor)
                .frame(width: 2, height: 36)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .center) {
                    // Tick strip
                    tickStrip
                        .frame(height: 48)
                }
        }
        .frame(height: 48)
        .clipped()
        .gesture(
            DragGesture(minimumDistance: 2)
                .updating($dragOffset) { value, state, _ in
                    state = value.translation.width
                }
                .onChanged { value in
                    let delta = -(value.translation.width - baseOffset) / tickSpacing
                    let newIdx = (selectedIndex + Int(delta.rounded())).clamped(to: 0...(values.count - 1))
                    if newIdx != selectedIndex {
                        selectedIndex = newIdx
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
                .onEnded { value in
                    baseOffset = 0
                }
        )
        .opacity(isLocked ? 0.4 : 1.0)
        .allowsHitTesting(!isLocked)
    }

    private var tickStrip: some View {
        GeometryReader { geo in
            let center = geo.size.width / 2
            let count = values.count
            let visibleCount = Int(geo.size.width / tickSpacing) + 4

            Canvas { ctx, size in
                let cur = selectedIndex
                let startIdx = max(0, cur - visibleCount / 2)
                let endIdx   = min(count - 1, cur + visibleCount / 2)

                for i in startIdx...endIdx {
                    let offset = CGFloat(i - cur) * tickSpacing + center
                    guard offset >= -tickSpacing && offset <= size.width + tickSpacing else { continue }

                    let isCurrent = i == cur
                    let isMajor   = i % 5 == 0
                    let height: CGFloat = isCurrent ? 26 : isMajor ? 20 : 13
                    let color: Color = isCurrent ? accentColor : (isMajor ? .white.opacity(0.6) : .white.opacity(0.25))
                    let width: CGFloat = isCurrent ? 2.5 : 1.5

                    let tickRect = CGRect(x: offset - width/2, y: size.height - height, width: width, height: height)
                    ctx.fill(Path(roundedRect: tickRect, cornerRadius: 1), with: .color(color))

                    // Label every 5 ticks and current
                    if isCurrent || isMajor {
                        let text = format(values[i])
                        let font: Font = isCurrent ? .system(size: 10, weight: .bold) : .system(size: 9, weight: .medium)
                        let resolved = ctx.resolve(Text(text).font(font).foregroundColor(isCurrent ? accentColor : .gray))
                        let size2 = resolved.measure(in: CGSize(width: 80, height: 20))
                        ctx.draw(resolved, at: CGPoint(x: offset - size2.width/2, y: 4))
                    }
                }
            }
        }
    }
}

// MARK: - Dial Card (tap to select parameter)
struct DialCard: View {
    let label: String
    let value: String
    let unit: String
    var isSelected: Bool = false
    var isLocked: Bool = false
    var showAuto: Bool = false

    var body: some View {
        VStack(spacing: 2) {
            if showAuto {
                Text("A")
                    .font(.system(size: 8, weight: .black))
                    .foregroundColor(.cyan)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 4)
            } else {
                Spacer().frame(height: 10)
            }

            Text(label)
                .font(.system(size: 9, weight: .bold))
                .kerning(0.8)
                .foregroundColor(.gray)
                .textCase(.uppercase)

            Text(value)
                .font(.system(size: 15, weight: .heavy, design: .monospaced))
                .foregroundColor(isSelected ? .yellow : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Text(unit)
                .font(.system(size: 8))
                .foregroundColor(.gray)
        }
        .frame(width: 70, height: 62)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(isSelected ? Color.yellow : Color.white.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
                )
        )
        .opacity(isLocked ? 0.4 : 1.0)
    }
}

// MARK: - Int clamping helper
extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

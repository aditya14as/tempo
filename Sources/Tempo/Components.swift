import SwiftUI

struct GradientBar: View {
    var fraction: Double
    var theme: Theme
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(theme.gradient)
                    .frame(width: max(height, geo.size.width * fraction))
                    .shadow(color: theme.colors.last!.opacity(0.45), radius: 4, y: 1)
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.6), value: fraction)
    }
}

struct GradientRing: View {
    var fraction: Double
    var theme: Theme
    var size: CGFloat = 46
    var lineWidth: CGFloat = 5
    var showsPercent: Bool = true

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    AngularGradient(colors: theme.colors + [theme.colors[0]], center: .center),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: fraction)
            if showsPercent {
                Text(ProgressEngine.percentText(fraction))
                    .font(.system(size: size * 0.26, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .frame(width: size, height: size)
    }
}

struct DotGrid: View {
    var fraction: Double
    var count: Int
    var theme: Theme
    var dotSize: CGFloat = 7

    private var filled: Int { Int((fraction * Double(count)).rounded()) }

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: dotSize, maximum: dotSize), spacing: 5)]
        LazyVGrid(columns: columns, spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(i < filled ? AnyShapeStyle(theme.gradient) : AnyShapeStyle(Color.primary.opacity(0.1)))
                    .frame(width: dotSize, height: dotSize)
            }
        }
    }
}

struct BigPercent: View {
    var fraction: Double?
    var theme: Theme
    var size: CGFloat = 26

    var body: some View {
        Text(ProgressEngine.percentText(fraction))
            .font(.system(size: size, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(fraction == nil ? AnyShapeStyle(Color.secondary) : AnyShapeStyle(theme.gradient))
    }
}

/// A label on the left, a mini switch pinned to the right edge.
struct SettingToggle: View {
    var label: String
    @Binding var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        self._isOn = isOn
    }

    var body: some View {
        HStack {
            Text(label).font(.system(.subheadline, design: .rounded))
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}

/// A segmented picker that becomes a pop-up menu when its segments don't fit
/// the width on offer, so a long option can't push Settings past the panel.
struct FittingPicker<Value: Hashable, Content: View>: View {
    @Binding var selection: Value
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Picker("", selection: $selection, content: content)
                .pickerStyle(.segmented)
            Picker("", selection: $selection, content: content)
                .pickerStyle(.menu)
                .fixedSize()
        }
        .labelsHidden()
    }
}

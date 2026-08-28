import CmuxFoundation
import CmuxSwiftRender
import SwiftUI

private enum RenderViewLimits {
    static let maxDimension = 10_000.0
    static let maxEffectRadius = 1_000.0
    static let maxFontSize = 256.0
    static let maxLineLimit = 10_000.0
    static let maxRatio = 1_000_000.0
    static let maxAngle = 360_000.0
}

private func renderFinite(_ value: Double?, maximum: Double = RenderViewLimits.maxDimension) -> Double? {
    guard let value, value.isFinite, abs(value) <= maximum else { return nil }
    return value
}

private func renderNonnegative(_ value: Double?, maximum: Double = RenderViewLimits.maxDimension) -> Double? {
    guard let value = renderFinite(value, maximum: maximum), value >= 0 else { return nil }
    return value
}

private func renderCGFloat(_ value: Double?, maximum: Double = RenderViewLimits.maxDimension, nonnegative: Bool = false) -> CGFloat? {
    let value = nonnegative ? renderNonnegative(value, maximum: maximum) : renderFinite(value, maximum: maximum)
    guard let value else { return nil }
    let result = CGFloat(value)
    return result.isFinite ? result : nil
}

/// Renders the Swift interpreter's ``RenderNode`` IR as native SwiftUI.
///
/// Modifier arguments arrive as source strings (e.g. `.title`, `.blue`, `8`)
/// and are applied best-effort; unknown modifiers are ignored. Button taps and
/// `.onTapGesture` actions are dispatched through ``sidebarActionDispatch``
/// from the environment.
struct RenderNodeView: View {
    let node: RenderNode

    @Environment(\.sidebarActionDispatch) private var dispatch

    var body: some View {
        let view = applyModifiers(content, node.modifiers)
        // A non-button node carrying an action (from `.onTapGesture`) becomes
        // tappable across its whole bounds.
        if node.kind != .button, let action = node.action {
            return AnyView(
                view.contentShape(Rectangle())
                    .onTapGesture { dispatch.run(action) }
                    .reportTapTarget(action)
            )
        }
        return view
    }

    @ViewBuilder
    private var content: some View {
        switch node.kind {
        case .vstack:
            VStack(alignment: .leading, spacing: renderCGFloat(node.spacing, nonnegative: true)) { children }
        case .hstack:
            HStack(spacing: renderCGFloat(node.spacing, nonnegative: true)) { children }
        case .zstack:
            ZStack { children }
        case .lazyVStack:
            LazyVStack(alignment: .leading, spacing: renderCGFloat(node.spacing, nonnegative: true)) { children }
        case .lazyHStack:
            LazyHStack(spacing: renderCGFloat(node.spacing, nonnegative: true)) { children }
        case .group:
            Group { children }
        case .list:
            // Plain, chrome-light list so it sits naturally in the sidebar
            // rather than imposing inset grouped-table styling.
            List { children }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
        case .section:
            VStack(alignment: .leading, spacing: 4) {
                if let header = node.text, !header.isEmpty {
                    Text(header)
                        .cmuxFont(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
                children
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .hscroll:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: renderCGFloat(node.spacing, nonnegative: true)) { children }
            }
        case .grid:
            Grid(alignment: .leading, horizontalSpacing: renderCGFloat(node.spacing, nonnegative: true),
                 verticalSpacing: renderCGFloat(node.spacing, nonnegative: true)) { children }
        case .gridRow:
            GridRow { children }
        case .lazyVGrid:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 60), spacing: renderCGFloat(node.spacing, nonnegative: true))],
                      spacing: renderCGFloat(node.spacing, nonnegative: true)) { children }
        case .lazyHGrid:
            LazyHGrid(rows: [GridItem(.adaptive(minimum: 40), spacing: renderCGFloat(node.spacing, nonnegative: true))],
                      spacing: renderCGFloat(node.spacing, nonnegative: true)) { children }
        case .viewThatFits:
            ViewThatFits { children }
        case .hsplit:
            ResizableHSplit(columns: node.children)
        case .reorderable:
            ReorderableList(rows: node.children, spec: node.reorder)
        case .text:
            Text(node.text ?? "")
        case .label:
            Label(node.text ?? "", systemImage: node.systemName ?? "circle")
        case .image:
            styledImage(Image(systemName: node.systemName ?? "questionmark.square.dashed"))
        case .button:
            if node.children.isEmpty {
                Button(node.text ?? "") {
                    if let action = node.action { dispatch.run(action) }
                }
                .reportTapTarget(node.action)
            } else {
                // Rich label form: `Button(action:){ label }`. Plain style so
                // the label renders as authored, not as default button chrome.
                Button {
                    if let action = node.action { dispatch.run(action) }
                } label: {
                    VStack(alignment: .leading, spacing: 0) { children }
                }
                .buttonStyle(.plain)
                .reportTapTarget(node.action)
            }
        case .spacer:
            Spacer(minLength: renderCGFloat(node.spacing, nonnegative: true))
        case .divider:
            Divider()
        case .rectangle:
            styledShape(Rectangle())
        case .roundedRectangle:
            styledShape(RoundedRectangle(cornerRadius: renderCGFloat(node.cornerRadius, maximum: 1_000, nonnegative: true) ?? 6))
        case .capsule:
            styledShape(Capsule())
        case .circle:
            styledShape(Circle())
        case .ellipse:
            styledShape(Ellipse())
        case .unevenRoundedRectangle:
            styledShape(RoundedRectangle(cornerRadius: renderCGFloat(node.cornerRadius, maximum: 1_000, nonnegative: true) ?? 6))
        case .progressView:
            if let value = renderFinite(node.value), value >= 0, value <= 1 {
                ProgressView(value: value) { if let t = node.text { Text(t) } }
            } else if let t = node.text {
                ProgressView(t)
            } else {
                ProgressView()
            }
        case .gauge:
            if let value = renderFinite(node.value), value >= 0, value <= 1 {
                Gauge(value: value) { if let t = node.text { Text(t) } }
            } else {
                EmptyView()
            }
        case .menu:
            Menu(node.text ?? "") { children }
        case .linearGradient:
            LinearGradient(colors: gradientColors(node),
                           startPoint: dslUnitPoint(node.points.first, default: .top),
                           endPoint: dslUnitPoint(node.points.count > 1 ? node.points[1] : nil, default: .bottom))
        case .radialGradient:
            RadialGradient(colors: gradientColors(node),
                           center: dslUnitPoint(node.points.first, default: .center),
                           startRadius: 0, endRadius: 90)
        case .angularGradient:
            AngularGradient(colors: gradientColors(node),
                            center: dslUnitPoint(node.points.first, default: .center))
        }
    }

    @ViewBuilder
    private var children: some View {
        ForEach(Array(node.children.enumerated()), id: \.offset) { _, child in
            RenderNodeView(node: child)
        }
    }

    private func applyModifiers(_ view: some View, _ modifiers: [RenderModifier]) -> AnyView {
        var result = AnyView(view)
        for modifier in modifiers {
            result = apply(modifier, to: result)
        }
        return result
    }

    private func apply(_ modifier: RenderModifier, to view: AnyView) -> AnyView {
        let token = clean(modifier.firstValue)
        switch modifier.name {
        case "font":
            return AnyView(view.modifier(OptionalDSLFont(spec: resolveFontSpec(token))))
        case "bold":
            return AnyView(view.fontWeight(.bold))
        case "strikethrough":
            return AnyView(view.strikethrough())
        case "underline":
            return AnyView(view.underline())
        case "italic":
            return AnyView(view.italic())
        case "monospaced":
            return AnyView(view.monospaced())
        case "monospacedDigit":
            return AnyView(view.monospacedDigit())
        case "fontWeight":
            return AnyView(view.fontWeight(dslFontWeight(token)))
        case "fontDesign":
            return AnyView(view.fontDesign(dslFontDesign(token)))
        case "multilineTextAlignment":
            return AnyView(view.multilineTextAlignment(dslTextAlignment(token)))
        case "textCase":
            return AnyView(view.textCase(dslTextCase(token)))
        case "truncationMode":
            return AnyView(view.truncationMode(dslTruncationMode(token)))
        case "foregroundColor", "foregroundStyle", "fill", "tint":
            if let color = dslColor(token) { return AnyView(view.foregroundStyle(color)) }
            return view
        case "padding":
            if let value = renderCGFloat(token.flatMap(Double.init), nonnegative: true) {
                return AnyView(view.padding(value))
            }
            return AnyView(view.padding())
        case "background":
            if !modifier.children.isEmpty {
                let alignment = frameAlignment(clean(modifier.value("alignment")))
                return AnyView(view.background(alignment: alignment) { modifierChildren(modifier) })
            }
            if let color = dslColor(token) { return AnyView(view.background(color)) }
            return view
        case "overlay":
            if !modifier.children.isEmpty {
                let alignment = frameAlignment(clean(modifier.value("alignment")))
                return AnyView(view.overlay(alignment: alignment) { modifierChildren(modifier) })
            }
            if let color = dslColor(token) { return AnyView(view.overlay(color)) }
            return view
        case "mask":
            if !modifier.children.isEmpty {
                return AnyView(view.mask { modifierChildren(modifier) })
            }
            return view
        case "safeAreaInset":
            if !modifier.children.isEmpty {
                let edge = clean(modifier.value("edge"))
                if edge == "top" {
                    return AnyView(view.safeAreaInset(edge: .top) { modifierChildren(modifier) })
                }
                return AnyView(view.safeAreaInset(edge: .bottom) { modifierChildren(modifier) })
            }
            return view
        case "cornerRadius":
            if let value = renderCGFloat(token.flatMap(Double.init), maximum: 1_000, nonnegative: true) {
                return AnyView(view.clipShape(RoundedRectangle(cornerRadius: value)))
            }
            return view
        case "opacity":
            if let value = token.flatMap(Double.init), value.isFinite {
                return AnyView(view.opacity(min(max(value, 0), 1)))
            }
            return view
        case "lineLimit":
            if let token, let value = Double(token), value.isFinite,
               value >= 0, value <= RenderViewLimits.maxLineLimit,
               let lineLimit = Int(exactly: value) {
                return AnyView(view.lineLimit(lineLimit))
            }
            return view
        case "frame":
            return applyFrame(modifier, to: view)
        case "shadow":
            let radius = renderNonnegative(modDouble(modifier, "radius") ?? token.flatMap(Double.init), maximum: RenderViewLimits.maxEffectRadius) ?? 4
            let color = dslColor(clean(modifier.value("color"))) ?? Color.black.opacity(0.33)
            return AnyView(view.shadow(color: color, radius: CGFloat(radius),
                                       x: renderCGFloat(modDouble(modifier, "x"), maximum: RenderViewLimits.maxDimension) ?? 0,
                                       y: renderCGFloat(modDouble(modifier, "y"), maximum: RenderViewLimits.maxDimension) ?? 0))
        case "border":
            let color = dslColor(token) ?? .secondary
            let width = renderNonnegative(modDouble(modifier, "width"), maximum: RenderViewLimits.maxEffectRadius) ?? 1
            return AnyView(view.border(color, width: CGFloat(width)))
        case "blur":
            let radius = renderNonnegative(modDouble(modifier, "radius") ?? token.flatMap(Double.init), maximum: RenderViewLimits.maxEffectRadius) ?? 0
            return AnyView(view.blur(radius: CGFloat(radius)))
        case "offset":
            return AnyView(view.offset(x: renderCGFloat(modDouble(modifier, "x")) ?? 0,
                                       y: renderCGFloat(modDouble(modifier, "y")) ?? 0))
        case "scaleEffect":
            if let s = renderFinite(token.flatMap(Double.init), maximum: 1_000) { return AnyView(view.scaleEffect(CGFloat(s))) }
            return view
        case "rotationEffect":
            return AnyView(view.rotationEffect(.degrees(angleDegrees(token) ?? 0)))
        case "zIndex":
            if let z = renderFinite(token.flatMap(Double.init), maximum: RenderViewLimits.maxDimension) { return AnyView(view.zIndex(z)) }
            return view
        case "brightness":
            return AnyView(view.brightness(renderFinite(token.flatMap(Double.init), maximum: 100) ?? 0))
        case "contrast":
            return AnyView(view.contrast(renderFinite(token.flatMap(Double.init), maximum: 100) ?? 1))
        case "saturation":
            return AnyView(view.saturation(renderFinite(token.flatMap(Double.init), maximum: 100) ?? 1))
        case "grayscale":
            return AnyView(view.grayscale(renderFinite(token.flatMap(Double.init), maximum: 1) ?? 0))
        case "clipShape":
            return applyClipShape(token, to: view)
        case "imageScale":
            return AnyView(view.imageScale(dslImageScale(token)))
        case "symbolRenderingMode":
            return AnyView(view.symbolRenderingMode(dslSymbolRenderingMode(token)))
        case "symbolVariant":
            return AnyView(view.symbolVariant(dslSymbolVariant(token)))
        case "contextMenu":
            if !modifier.children.isEmpty {
                return AnyView(view.contextMenu { modifierChildren(modifier) })
            }
            return view
        case "help":
            if let token { return AnyView(view.help(LocalizedStringKey(token))) }
            return view
        case "keyboardShortcut":
            guard let key = dslKeyEquivalent(token) else { return view }
            return AnyView(view.keyboardShortcut(key, modifiers: dslEventModifiers(modifier.value("modifiers"))))
        case "disabled":
            // Disabled only when the arg explicitly resolves to true; an
            // unresolved expression defaults to enabled, not disabled.
            return AnyView(view.disabled(token == "true"))
        case "redacted":
            let reason = clean(modifier.value("reason")) ?? token
            return AnyView(view.redacted(reason: reason == "invalidated" ? .invalidated : .placeholder))
        case "unredacted":
            return AnyView(view.unredacted())
        case "accessibilityLabel":
            return AnyView(view.accessibilityLabel(Text(token ?? "")))
        case "accessibilityHint":
            return AnyView(view.accessibilityHint(Text(token ?? "")))
        case "accessibilityValue":
            return AnyView(view.accessibilityValue(Text(token ?? "")))
        case "accessibilityHidden":
            return AnyView(view.accessibilityHidden(token != "false"))
        case "scrollIndicators":
            return AnyView(view.scrollIndicators(token == "hidden" || token == "never" ? .hidden : .visible))
        case "scrollContentBackground":
            return AnyView(view.scrollContentBackground(token == "hidden" ? .hidden : .visible))
        case "aspectRatio":
            let mode: ContentMode = clean(modifier.value("contentMode")) == "fill" ? .fill : .fit
            // Only apply an explicit ratio when positive; a zero/negative ratio
            // is invalid in SwiftUI, so fall back to mode-only.
            if let ratio = renderFinite(token.flatMap(Double.init), maximum: RenderViewLimits.maxRatio), ratio > 0 {
                return AnyView(view.aspectRatio(CGFloat(ratio), contentMode: mode))
            }
            return AnyView(view.aspectRatio(contentMode: mode))
        case "scaledToFit":
            return AnyView(view.aspectRatio(contentMode: .fit))
        case "scaledToFill":
            return AnyView(view.aspectRatio(contentMode: .fill))
        case "clipped":
            return AnyView(view.clipped())
        case "fixedSize":
            return AnyView(view.fixedSize())
        case "layoutPriority":
            return AnyView(view.layoutPriority(renderFinite(token.flatMap(Double.init), maximum: RenderViewLimits.maxDimension) ?? 0))
        default:
            return view
        }
    }

    /// Renders an image, applying `.resizable()` on the concrete `Image` before
    /// erasure (it's an `Image` method, unavailable on `AnyView`). `.scaledToFit`/
    /// `.aspectRatio` from the generic modifier pass then apply on top.
    private func styledImage(_ image: Image) -> AnyView {
        if node.modifiers.contains(where: { $0.name == "resizable" }) {
            return AnyView(image.resizable())
        }
        return AnyView(image)
    }

    /// Resolves a gradient node's color stops, falling back to two clear stops
    /// so an empty/unresolved gradient is harmless rather than invalid.
    private func gradientColors(_ node: RenderNode) -> [Color] {
        let resolved = node.colors.compactMap { dslColor($0) }
        return resolved.count >= 2 ? resolved : (resolved + [.clear, .clear])
    }

    /// Renders a shape, applying shape-level `.trim` then `.stroke` /
    /// `.strokeBorder` (which must act on the concrete `Shape` before erasure).
    /// With no stroke the plain shape is returned so `.fill`/`.foregroundColor`
    /// from the generic modifier pass fills it.
    private func styledShape(_ shape: some Shape) -> AnyView {
        var resolved = AnyShape(shape)
        if let trim = node.modifiers.first(where: { $0.name == "trim" }) {
            resolved = AnyShape(resolved.trim(
                from: renderCGFloat(modDouble(trim, "from"), maximum: 1, nonnegative: true) ?? 0,
                to: renderCGFloat(modDouble(trim, "to"), maximum: 1, nonnegative: true) ?? 1
            ))
        }
        if let stroke = node.modifiers.first(where: { $0.name == "stroke" || $0.name == "strokeBorder" }) {
            let color = dslColor(clean(stroke.firstValue)) ?? .secondary
            let width = renderNonnegative(modDouble(stroke, "lineWidth"), maximum: RenderViewLimits.maxEffectRadius) ?? 1
            return AnyView(resolved.stroke(color, lineWidth: CGFloat(width)))
        }
        return AnyView(resolved)
    }

    /// Renders a child-bearing modifier's subtree (overlay/background/mask
    /// content). Multiple top-level views stack in a `ZStack`.
    @ViewBuilder
    private func modifierChildren(_ modifier: RenderModifier) -> some View {
        if modifier.children.count == 1 {
            RenderNodeView(node: modifier.children[0])
        } else {
            ZStack {
                ForEach(Array(modifier.children.enumerated()), id: \.offset) { _, child in
                    RenderNodeView(node: child)
                }
            }
        }
    }

    /// A labeled `Double` argument of a modifier (e.g. `.shadow(radius: 4)`).
    private func modDouble(_ modifier: RenderModifier, _ label: String) -> Double? {
        modifier.value(label).map { clean($0) ?? $0 }.flatMap(Double.init).flatMap { renderFinite($0) }
    }

    /// Degrees from an angle token like `.degrees(45)` or `.radians(1.5)`.
    private func angleDegrees(_ token: String?) -> Double? {
        guard let token else { return nil }
        if let open = token.firstIndex(of: "("), let close = token.lastIndex(of: ")") {
            let inner = String(token[token.index(after: open)..<close])
            guard let value = Double(inner.trimmingCharacters(in: .whitespaces)), value.isFinite else { return nil }
            let degrees = token.contains("radians") ? value * 180 / .pi : value
            return renderFinite(degrees, maximum: RenderViewLimits.maxAngle)
        }
        return renderFinite(Double(token), maximum: RenderViewLimits.maxAngle)
    }

    /// Resolves a `.clipShape(<Shape>())` token to a clip.
    private func applyClipShape(_ token: String?, to view: AnyView) -> AnyView {
        switch token.map({ $0.lowercased() }) {
        case let t? where t.hasPrefix("circle"): return AnyView(view.clipShape(Circle()))
        case let t? where t.hasPrefix("capsule"): return AnyView(view.clipShape(Capsule()))
        case let t? where t.hasPrefix("ellipse"): return AnyView(view.clipShape(Ellipse()))
        case let t? where t.hasPrefix("rectangle"): return AnyView(view.clipShape(Rectangle()))
        default: return AnyView(view.clipShape(RoundedRectangle(cornerRadius: 8)))
        }
    }

    /// Applies `.frame(width:height:minWidth:maxWidth:alignment:)` from the
    /// modifier's labeled arguments (`.infinity` supported for max bounds).
    private func applyFrame(_ modifier: RenderModifier, to view: AnyView) -> AnyView {
        func dim(_ label: String) -> CGFloat? {
            guard let raw = modifier.value(label) else { return nil }
            if (raw == ".infinity" || raw == "infinity") && (label == "maxWidth" || label == "maxHeight") {
                return .infinity
            }
            return renderCGFloat(Double(raw), nonnegative: true)
        }
        let alignment = frameAlignment(clean(modifier.value("alignment")))
        return AnyView(
            view.frame(
                minWidth: dim("minWidth"),
                maxWidth: dim("maxWidth"),
                minHeight: dim("minHeight"),
                maxHeight: dim("maxHeight"),
                alignment: alignment
            )
            .frame(width: dim("width"), height: dim("height"))
        )
    }

    private func frameAlignment(_ token: String?) -> Alignment {
        switch token {
        case "leading": return .leading
        case "trailing": return .trailing
        case "top": return .top
        case "bottom": return .bottom
        case "topLeading": return .topLeading
        case "topTrailing": return .topTrailing
        case "bottomLeading": return .bottomLeading
        case "bottomTrailing": return .bottomTrailing
        default: return .center
        }
    }

    /// Resolves a font token, including the `.system(size:weight:design:)` /
    /// `.system(.style, design:)` forms (size, monospaced design, named style).
    private func resolveFontSpec(_ token: String?) -> DSLFontSpec? {
        guard let token else { return nil }
        guard token.hasPrefix("system") else { return dslFontSpec(named: token, size: nil) }
        let design: Font.Design = token.contains("monospaced") ? .monospaced : .default
        let weight = resolveFontWeight(in: token)
        if let range = token.range(of: "size:") {
            let digits = token[range.upperBound...].drop(while: { $0 == " " })
                .prefix(while: { $0.isNumber || $0 == "." })
            if let n = renderNonnegative(Double(digits), maximum: RenderViewLimits.maxFontSize), n > 0 {
                return dslFontSpec(named: nil, size: n, weight: weight, design: design)
            }
        }
        let styleNames = [
            "largeTitle", "title3", "title2", "title",
            "headline", "subheadline", "body", "callout",
            "footnote", "caption2", "caption",
        ]
        for name in styleNames where token.contains(name) {
            return dslFontSpec(named: name, size: nil, weight: weight, design: design)
        }
        return dslFontSpec(named: nil, size: 13, weight: weight, design: design)
    }

    private func resolveFontWeight(in token: String) -> Font.Weight? {
        guard let range = token.range(of: "weight:") else { return nil }
        let rawWeight = token[range.upperBound...].drop(while: { $0 == " " || $0 == "." })
            .prefix(while: { $0.isLetter })
        return dslFontWeight(String(rawWeight))
    }

    /// Strips a leading `.` (member token) or surrounding quotes from a raw
    /// modifier argument so color/font/alignment tokens resolve.
    private func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if raw.hasPrefix(".") { return String(raw.dropFirst()) }
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }
}

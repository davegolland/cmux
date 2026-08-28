import CmuxFoundation
import SwiftUI

private enum DSLRenderLimits {
    static let maxDimension = 10_000.0
}

private func dslDimension(_ value: Double?, nonnegative: Bool = true) -> CGFloat? {
    guard let value, value.isFinite, abs(value) <= DSLRenderLimits.maxDimension,
          !nonnegative || value >= 0 else { return nil }
    let result = CGFloat(value)
    return result.isFinite ? result : nil
}

/// Renders a declarative JSON ``DSLNode`` tree as native SwiftUI.
///
/// `onAction` is invoked when an interactive node fires. The JSON format is
/// the simpler, static alternative to the interpreted Swift path.
struct DSLSidebarRenderer: View {
    let node: DSLNode
    let onAction: (DSLAction) -> Void

    var body: some View {
        styled(content)
    }

    @ViewBuilder
    private var content: some View {
        switch node.type {
        case .vstack:
            VStack(alignment: dslHAlignment(node.alignment), spacing: dslDimension(node.spacing)) {
                childViews
            }
        case .hstack:
            HStack(alignment: dslVAlignment(node.alignment), spacing: dslDimension(node.spacing)) {
                childViews
            }
        case .zstack:
            ZStack { childViews }
        case .text:
            Text(node.text ?? "")
                .modifier(OptionalDSLFont(spec: resolvedFontSpec))
                .fontWeight(dslFontWeight(node.weight))
        case .button:
            Button(node.title ?? "") {
                if let action = node.action { onAction(action) }
            }
            .reportTapTarget(node.action?.buttonAction)
        case .image:
            Image(systemName: node.systemName ?? "questionmark.square.dashed")
                .modifier(OptionalDSLFont(spec: resolvedFontSpec))
        case .spacer:
            Spacer(minLength: dslDimension(node.size))
        case .divider:
            Divider()
        }
    }

    @ViewBuilder
    private var childViews: some View {
        ForEach(node.children ?? []) { child in
            DSLSidebarRenderer(node: child, onAction: onAction)
        }
    }

    private var resolvedFontSpec: DSLFontSpec? {
        dslFontSpec(named: node.font, size: node.size)
    }

    @ViewBuilder
    private func styled(_ view: some View) -> some View {
        view
            .modifier(OptionalForeground(color: dslColor(node.color)))
            .modifier(OptionalPadding(padding: dslDimension(node.padding)))
            .modifier(OptionalBackground(color: dslColor(node.background)))
    }
}

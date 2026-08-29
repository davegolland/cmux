import AppKit
import CmuxAgentChat

// MARK: - Grid metrics

/// Cell geometry of a terminal surface in view points, top-origin.
///
/// Mirrors the fields `GhosttyNSView.keyboardCopyModeGridMetrics(surface:)`
/// reads from `ghostty_surface_grid_metrics`, minus the view height: the math
/// overlay is a flipped view, so it draws directly in top-origin coordinates.
struct TerminalMathGridMetrics: Equatable, Sendable {
    /// Width of one cell in points.
    let cellWidth: CGFloat
    /// Height of one cell in points.
    let cellHeight: CGFloat
    /// Left padding before column 0.
    let xInset: CGFloat
    /// Top padding before row 0.
    let yInset: CGFloat

    /// Creates grid metrics.
    init(cellWidth: CGFloat, cellHeight: CGFloat, xInset: CGFloat, yInset: CGFloat) {
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.xInset = xInset
        self.yInset = yInset
    }

    /// Top-origin rect covering `segment`'s cells.
    func rect(for segment: TerminalMathPlacement.Segment) -> CGRect {
        CGRect(
            x: xInset + CGFloat(segment.startColumn) * cellWidth,
            y: yInset + CGFloat(segment.row) * cellHeight,
            width: CGFloat(max(segment.endColumn - segment.startColumn, 0)) * cellWidth,
            height: cellHeight
        )
    }
}

// MARK: - Layout

/// Pure placement geometry for one rendered formula over its source cells.
///
/// All rects are top-origin (the overlay view is flipped). The fit rule:
/// the raster is drawn at natural size when its height fits the row budget
/// (`cellHeight` inline, `2 * cellHeight` for display math, which may overhang
/// half a cell above and below its row); when it is wider than the first
/// segment's patch or taller than the budget it is scaled down uniformly, and
/// a placement whose scaled height would drop below
/// ``minimumHeightFactor`` × `cellHeight` is rejected so the raw text stays.
enum TerminalMathOverlayLayout {
    /// Point-size metrics of a raster, decoupled from the image itself.
    struct RasterSize: Equatable, Sendable {
        /// Natural width in points.
        let widthPt: CGFloat
        /// Natural height in points.
        let heightPt: CGFloat
        /// Distance from the top of the raster to the text baseline, in points.
        let baselinePt: CGFloat

        /// Creates raster metrics.
        init(widthPt: CGFloat, heightPt: CGFloat, baselinePt: CGFloat) {
            self.widthPt = widthPt
            self.heightPt = heightPt
            self.baselinePt = baselinePt
        }
    }

    /// The rects the overlay paints for one placement.
    struct Frame: Equatable, Sendable {
        /// Opaque background patches, one per segment, covering the source cells.
        let patchRects: [CGRect]
        /// Where the raster image is drawn.
        let imageRect: CGRect
        /// Uniform scale applied to the raster (1 when drawn at natural size).
        let scale: CGFloat
    }

    /// Maximum raster height, in cells, for inline math.
    static let inlineMaxHeightFactor: CGFloat = 1.0
    /// Maximum raster height, in cells, for display math.
    static let displayMaxHeightFactor: CGFloat = 2.0
    /// A scaled-down raster shorter than this fraction of a cell is not drawn.
    static let minimumHeightFactor: CGFloat = 0.7

    /// Computes the frame for `placement`, or nil when the fit rule rejects it.
    ///
    /// - Parameters:
    ///   - placement: The formula's cells on the grid.
    ///   - raster: Natural size of the rendered formula.
    ///   - metrics: Cell geometry of the surface.
    ///   - isDisplay: Whether to use the display-math height budget.
    /// - Returns: Patch and image rects in top-origin coordinates, or nil.
    static func frame(
        for placement: TerminalMathPlacement,
        raster: RasterSize,
        metrics: TerminalMathGridMetrics,
        isDisplay: Bool
    ) -> Frame? {
        guard metrics.cellWidth > 0, metrics.cellHeight > 0,
              raster.widthPt > 0, raster.heightPt > 0,
              raster.widthPt.isFinite, raster.heightPt.isFinite else { return nil }

        let segments = placement.segments
        let patchRects = segments.map { metrics.rect(for: $0) }
        guard let anchor = patchRects.first, anchor.width > 0 else { return nil }

        let maxHeight = metrics.cellHeight
            * (isDisplay ? displayMaxHeightFactor : inlineMaxHeightFactor)
        let widthScale = anchor.width / raster.widthPt
        let heightScale = maxHeight / raster.heightPt
        let scale = min(1, widthScale, heightScale)
        if scale < 1, raster.heightPt * scale < metrics.cellHeight * minimumHeightFactor {
            return nil
        }

        let width = raster.widthPt * scale
        let height = raster.heightPt * scale
        // Centered on the first row both ways. The image is centered
        // vertically rather than baseline-aligned because Ghostty does not
        // expose the glyph baseline within a cell through the grid metrics;
        // the raster's `baselinePt` is carried in ``RasterSize`` so a future
        // metric can switch this to baseline alignment without touching callers.
        let imageRect = CGRect(
            x: anchor.minX + (anchor.width - width) / 2,
            y: anchor.minY + (anchor.height - height) / 2,
            width: width,
            height: height
        )
        return Frame(patchRects: patchRects, imageRect: imageRect, scale: scale)
    }
}

// MARK: - Model

/// What the overlay currently paints.
struct TerminalMathOverlayModel {
    /// One drawable placement: its patches, image rect, and image.
    struct Item {
        /// Opaque patches over the source cells.
        let patchRects: [CGRect]
        /// Destination rect of the raster.
        let imageRect: CGRect
        /// The rendered formula.
        let image: NSImage
    }

    /// Placements with a cached raster that passed the fit rule.
    var items: [Item] = []
    /// Terminal background color used for the patches.
    var backgroundColor: NSColor = .clear
}

// MARK: - Overlay view

/// Pass-through overlay that paints rendered math over the terminal's source
/// cells.
///
/// A sibling of `GhosttyFlashOverlayView` (which is `final`): it never takes
/// focus and returns nil from `hitTest` so the surface view's local event
/// monitor, which requires `hitTest(location) == self`, keeps working. The
/// view is flipped so ``TerminalMathOverlayLayout`` rects apply directly.
final class TerminalMathOverlayView: NSView {
    /// The current placements; setting it repaints.
    var model = TerminalMathOverlayModel() {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override var acceptsFirstResponder: Bool { false }

    override var isFlipped: Bool { true }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !model.items.isEmpty, let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        defer { context.restoreGraphicsState() }
        context.imageInterpolation = .high

        model.backgroundColor.setFill()
        for item in model.items {
            for patch in item.patchRects where patch.intersects(dirtyRect) {
                patch.fill()
            }
        }
        for item in model.items where item.imageRect.intersects(dirtyRect) {
            item.image.draw(
                in: item.imageRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
        }
    }
}

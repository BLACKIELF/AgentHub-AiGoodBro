import AppKit

enum TokenMonitorEdgeDockNativeGeometrySelfTest {
    static func run() -> Bool {
        let work = NSRect(x: 100, y: 50, width: 1_200, height: 760)
        let height: CGFloat = 412
        let top = TokenMonitorEdgeDockNativeGeometry.railFrame(
            workArea: work, side: .right, offset: 0, height: height
        )
        let bottom = TokenMonitorEdgeDockNativeGeometry.railFrame(
            workArea: work, side: .right, offset: 1, height: height
        )
        let left = TokenMonitorEdgeDockNativeGeometry.railFrame(
            workArea: work, side: .left, offset: 0.3, height: height
        )
        let crossed = TokenMonitorEdgeDockNativeGeometry.placementAfterDrag(
            rail: top, translation: CGSize(width: -1_100, height: 1_000), destinationWorkArea: work
        )
        let leftCard = TokenMonitorEdgeDockNativeGeometry.cardFrame(
            rail: left, centerY: work.maxY - 25, height: 360, workArea: work, side: .left
        )
        let rightCard = TokenMonitorEdgeDockNativeGeometry.cardFrame(
            rail: top, centerY: work.minY + 20, height: 360, workArea: work, side: .right
        )
        let short = NSRect(x: -1_440, y: 0, width: 840, height: 250)
        let clamped = TokenMonitorEdgeDockNativeGeometry.railFrame(
            workArea: short, side: .right, offset: 0.3, height: 1_000
        )
        let shortCard = TokenMonitorEdgeDockNativeGeometry.cardFrame(
            rail: clamped, centerY: short.midY, height: 900, workArea: short, side: .right
        )
        let passed =
            top.maxX == work.maxX && top.maxY == work.maxY - 8
            && bottom.minY == work.minY + 8
            && left.minX == work.minX
            && crossed.side == .left && crossed.offset == 1
            && leftCard.minX > left.maxX && leftCard.maxY <= work.maxY - 8
            && rightCard.maxX < top.minX && rightCard.minY >= work.minY + 8
            && clamped.minX < 0 && clamped.maxX == short.maxX
            && clamped.minY >= short.minY + 8 && clamped.maxY <= short.maxY - 8
            && shortCard.minY >= short.minY + 8 && shortCard.maxY <= short.maxY - 8
        if !passed { print("edge-dock native geometry self-test failed: right/left, drop, or short multi-display bounds") }
        return passed
    }
}

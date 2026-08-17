import CoreGraphics

struct DependencyViewport {
    static func clampedScale(_ value: CGFloat) -> CGFloat {
        min(max(value, 0.6), 1.8)
    }

    static func offsetToReveal(
        contentRect: CGRect,
        viewportSize: CGSize,
        scale: CGFloat,
        currentOffset: CGSize,
        margin: CGFloat
    ) -> CGSize {
        let transformed = CGRect(
            x: contentRect.minX * scale + currentOffset.width,
            y: contentRect.minY * scale + currentOffset.height,
            width: contentRect.width * scale,
            height: contentRect.height * scale
        )
        var deltaX: CGFloat = 0
        var deltaY: CGFloat = 0

        if transformed.minX < margin {
            deltaX = margin - transformed.minX
        } else if transformed.maxX > viewportSize.width - margin {
            deltaX = viewportSize.width - margin - transformed.maxX
        }

        if transformed.minY < margin {
            deltaY = margin - transformed.minY
        } else if transformed.maxY > viewportSize.height - margin {
            deltaY = viewportSize.height - margin - transformed.maxY
        }

        return CGSize(
            width: currentOffset.width + deltaX,
            height: currentOffset.height + deltaY
        )
    }
}

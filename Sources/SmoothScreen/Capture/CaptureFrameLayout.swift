import CoreGraphics

struct CaptureFrameLayout {
    let outputSize: CGSize

    func pixelContentRect(
        metadataRect: CGRect?,
        scaleFactor: Double,
        imageExtent: CGRect
    ) -> CGRect {
        guard
            let metadataRect,
            metadataRect.width > 0,
            metadataRect.height > 0
        else { return imageExtent }

        let density = max(1, scaleFactor)
        let scaledRect = CGRect(
            x: metadataRect.minX * density,
            y: metadataRect.minY * density,
            width: metadataRect.width * density,
            height: metadataRect.height * density
        )
        let rawRect = metadataRect
        let outputRect = fits(scaledRect, inside: imageExtent) ? scaledRect : rawRect
        let coreImageRect = CGRect(
            x: outputRect.minX,
            y: imageExtent.maxY - outputRect.maxY,
            width: outputRect.width,
            height: outputRect.height
        ).intersection(imageExtent)
        return coreImageRect.width > 0 && coreImageRect.height > 0
            ? coreImageRect
            : imageExtent
    }

    func transformToFill(contentRect: CGRect) -> CGAffineTransform {
        guard
            outputSize.width > 0,
            outputSize.height > 0,
            contentRect.width > 0,
            contentRect.height > 0
        else { return .identity }

        let scale = max(
            outputSize.width / contentRect.width,
            outputSize.height / contentRect.height
        )
        let scaledWidth = contentRect.width * scale
        let scaledHeight = contentRect.height * scale
        let targetOrigin = CGPoint(
            x: (outputSize.width - scaledWidth) / 2,
            y: (outputSize.height - scaledHeight) / 2
        )

        return CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: scale,
            tx: targetOrigin.x - (contentRect.minX * scale),
            ty: targetOrigin.y - (contentRect.minY * scale)
        )
    }

    private func fits(_ rect: CGRect, inside bounds: CGRect) -> Bool {
        let tolerance = 2.0
        return rect.minX >= bounds.minX - tolerance
            && rect.minY >= bounds.minY - tolerance
            && rect.maxX <= bounds.maxX + tolerance
            && rect.maxY <= bounds.maxY + tolerance
    }
}

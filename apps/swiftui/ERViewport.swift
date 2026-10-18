// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics

struct ERViewport: Codable {
  var zoom = 1.0
  var panX = 0.0
  var panY = 0.0
  var calibration = 1.0

  /// Preserve the world point under a local canvas point, using the gesture's
  /// original viewport for every update to avoid cumulative rounding drift.
  func zoomed(to requestedZoom: Double, at anchor: CGPoint) -> ERViewport {
    var result = self
    result.zoom = min(4, max(0.0001, requestedZoom))
    let oldScale = zoom * calibration
    let newScale = result.zoom * calibration
    result.panX += anchor.x / oldScale - anchor.x / newScale
    result.panY += anchor.y / oldScale - anchor.y / newScale
    return result
  }

  /// Pan just enough to reveal a new object. If it is larger than the viewport,
  /// keep its leading edge/header visible without changing the user's zoom.
  func revealing(_ rect: CGRect, in canvas: CGSize) -> ERViewport {
    guard canvas.width > 0, canvas.height > 0 else { return self }
    let scale = zoom * calibration
    func pan(_ current: Double, _ start: Double, _ length: Double, _ viewport: Double) -> Double {
      // Reserve room for a scrollbar that may appear after insertion.
      let visible = max(1, viewport - 14)
      let inset = min(24, visible / 4)
      let leading = start - inset / scale
      let trailing = start + length - (visible - inset) / scale
      if length * scale > visible - 2 * inset { return leading }
      return min(leading, max(trailing, current))
    }
    var result = self
    result.panX = pan(panX, rect.minX, rect.width, canvas.width)
    result.panY = pan(panY, rect.minY, rect.height, canvas.height)
    return result
  }

  var zoomLabel: String {
    zoom < 0.01 ? String(format: "%.2f%%", zoom * 100) : "\(Int((zoom * 100).rounded()))%"
  }
}

// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics

/// Model-space arrowhead: the tip stops outside the destination port so the
/// circle cannot cover it. Transform every point with the canvas scale.
func erArrowhead(_ destination: CGPoint, hasPort: Bool = true) -> [CGPoint] {
  let tip = CGPoint(x: destination.x - (hasPort ? 7 : 0), y: destination.y)
  return [CGPoint(x: tip.x - 8, y: tip.y - 5), tip, CGPoint(x: tip.x - 8, y: tip.y + 5)]
}

func erRouteMidpoint(_ points: [CGPoint]) -> CGPoint? {
  guard points.count >= 2 else { return nil }
  let segments = Array(zip(points, points.dropFirst()))
  var remaining = segments.reduce(0.0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } / 2
  for (a, b) in segments {
    let length = hypot(b.x - a.x, b.y - a.y)
    if length > 0 && remaining <= length {
      let fraction = remaining / length
      return CGPoint(x: a.x + fraction * (b.x - a.x), y: a.y + fraction * (b.y - a.y))
    }
    remaining -= length
  }
  return points.first
}

/// World-space label bounds, kept outside every card and previously placed label.
/// Start just outside the endpoint; crowded layouts move the label above obstacles.
func erEndpointLabelRect(endpoint: CGPoint, source: Bool, size: CGSize,
                         obstacles: [CGRect], gap: Double) -> CGRect {
  var rect = CGRect(x: source ? endpoint.x + gap : endpoint.x - gap - size.width,
                    y: endpoint.y - gap - size.height, width: size.width, height: size.height)
  for _ in 0...obstacles.count {
    let hits = obstacles.filter { $0.insetBy(dx: -gap, dy: -gap).intersects(rect) }
    guard let top = hits.map(\.minY).min() else { return rect }
    rect.origin.y = top - gap - size.height - 0.01
  }
  return rect
}

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

extension ERViewport {
  /// Presentation-only camera motion. The document already contains the final view.
  func panned(toward target: ERViewport, progress: Double) -> ERViewport {
    let t = min(1, max(0, progress))
    let eased = t * t * (3 - 2 * t)
    var result = target
    result.panX = panX + (target.panX - panX) * eased
    result.panY = panY + (target.panY - panY) * eased
    return result
  }
}

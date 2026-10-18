// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics

@main
enum ViewportTests {
  static func main() throws {
    // Check the externally visible invariant: the world point under the initial
    // finger midpoint must still project to that same screen point after zoom.
    for zoom in [0.0001, 0.25, 1.0, 4.0] {
      for calibration in [0.25, 1.0, 1.7, 4.0] {
        for pan in [-1200.0, 0, 320] {
          let original = ERViewport(zoom: zoom, panX: pan, panY: -pan, calibration: calibration)
          for anchor in [CGPoint.zero, CGPoint(x: 31, y: 177), CGPoint(x: 314, y: 651)] {
            let world = CGPoint(x: pan + anchor.x / (zoom * calibration),
                                y: -pan + anchor.y / (zoom * calibration))
            for requested in [0.000001, 0.25, 0.5, 1.0, 2.0, 40.0] {
              let result = original.zoomed(to: requested, at: anchor)
              let screen = CGPoint(x: (world.x - result.panX) * result.zoom * calibration,
                                   y: (world.y - result.panY) * result.zoom * calibration)
              assert(abs(screen.x - anchor.x) < 0.00001)
              assert(abs(screen.y - anchor.y) < 0.00001)
              assert((0.0001...4).contains(result.zoom))
            }
          }
        }
      }
    }
    // Creation must reveal the whole rectangle when it fits, or the leading
    // edge/header when it does not, across phone/desktop sizes and camera offsets.
    for canvas in [CGSize(width: 428, height: 600), CGSize(width: 900, height: 500)] {
      for zoom in [0.0001, 0.25, 1.0, 2.0, 4.0] {
        for calibration in [0.25, 1.0, 4.0] {
          for position in [CGPoint.zero, CGPoint(x: 800, y: 900), CGPoint(x: 100000, y: 100000)] {
            let original = ERViewport(zoom: zoom, panX: -500, panY: 12000, calibration: calibration)
            let rect = CGRect(origin: position, size: CGSize(width: 320, height: 64))
            let result = original.revealing(rect, in: canvas)
            let scale = zoom * calibration
            let left = (rect.minX - result.panX) * scale
            let top = (rect.minY - result.panY) * scale
            assert(result.zoom == zoom && result.calibration == calibration)
            assert(left >= 24 - 1e-6 && top >= 24 - 1e-6)
            if rect.width * scale <= canvas.width - 62 {
              assert(left + rect.width * scale <= canvas.width - 38 + 1e-6)
            } else { assert(abs(left - 24) < 1e-6) }
            if rect.height * scale <= canvas.height - 62 {
              assert(top + rect.height * scale <= canvas.height - 38 + 1e-6)
            } else { assert(abs(top - 24) < 1e-6) }
          }
        }
      }
    }
    // Reveal motion must preserve zoom, move continuously, and stop at exact endpoints.
    let start = ERViewport(zoom: 2, panX: -500, panY: 800, calibration: 1.3)
    let target = ERViewport(zoom: 2, panX: 1200, panY: -300, calibration: 1.3)
    var previous = start
    for progress in stride(from: 0.0, through: 1.0, by: 0.05) {
      let sample = start.panned(toward: target, progress: progress)
      assert(sample.panX >= previous.panX && sample.panY <= previous.panY)
      assert(sample.zoom == 2 && sample.calibration == 1.3)
      previous = sample
    }
    assert(start.panned(toward: target, progress: -1).panX == start.panX)
    assert(start.panned(toward: target, progress: 2).panY == target.panY)
    assert(start.panned(toward: target, progress: 0.5).panX == 350)
    let visible = ERViewport(panX: 10, panY: 20)
    let unchanged = visible.revealing(CGRect(x: 50, y: 60, width: 320, height: 64), in: CGSize(width: 900, height: 600))
    assert(unchanged.panX == visible.panX && unchanged.panY == visible.panY)
    let noLayout = visible.revealing(CGRect(x: 5000, y: 9000, width: 320, height: 64), in: .zero)
    assert(noLayout.panX == visible.panX && noLayout.panY == visible.panY)
    let anchor = CGPoint(x: 70, y: 150)
    let initial = ERViewport()
    let out = initial.zoomed(to: 0.25, at: anchor)
    assert(out.panX == -210 && out.panY == -450) // No origin clamp may move the anchor.
    let restored = out.zoomed(to: 1, at: anchor)
    assert(abs(restored.panX) < 1e-10 && abs(restored.panY) < 1e-10)
    let encoded = try JSONEncoder().encode(out)
    let decoded = try JSONDecoder().decode(ERViewport.self, from: encoded)
    assert(decoded.panX == out.panX && decoded.panY == out.panY && decoded.zoom == out.zoom)
    assert(out.zoomLabel == "25%")
    assert(ERViewport(zoom: 0.0001).zoomLabel == "0.01%")
    print("Anchored zoom, calibration, limits, signed camera offsets round-trip and new-table visibility tests passed.")
  }
}

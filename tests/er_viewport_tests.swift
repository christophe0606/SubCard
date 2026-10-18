// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics

@main
enum ViewportTests {
  static func main() throws {
    // A scaled arrowhead keeps the same size relative to the port, with its
    // tip outside the port circle instead of hidden beneath it.
    let destination = CGPoint(x: 100, y: 30)
    let head = erArrowhead(destination)
    for zoom in [0.25, 1.0, 4.0] {
      for calibration in [0.25, 1.0, 4.0] {
        let scale = zoom * calibration
        assert((destination.x - head[1].x) * scale > 6 * scale)
        assert(abs((head[1].x - head[0].x) * scale / (6 * scale) - 8.0 / 6) < 1e-9)
      }
    }
    assert(erArrowhead(destination, hasPort: false)[1] == destination)
    // Cardinality belongs halfway along the whole path, including when the
    // middle segment has zero length or the longest segment is off center.
    let straight = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
                    CGPoint(x: 100, y: 0), CGPoint(x: 200, y: 0)]
    assert(erRouteMidpoint(straight) == CGPoint(x: 100, y: 0))
    assert(erRouteMidpoint([CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 0), CGPoint(x: 20, y: 100)])
      == CGPoint(x: 20, y: 40))
    assert(erRouteMidpoint([]) == nil)
    // Labels must clear cards and each other for narrow gaps, self links,
    // reversed endpoints, long labels, zoom and display calibration.
    let cards = [CGRect(x: 10, y: 100, width: 320, height: 64),
                 CGRect(x: 355, y: 100, width: 320, height: 64),
                 CGRect(x: 0, y: 20, width: 320, height: 64)]
    for scale in [0.01, 0.25, 1.0, 4.0, 16.0] {
      var obstacles = cards
      for endpoint in [CGPoint(x: 355, y: 130), CGPoint(x: 10, y: 130), CGPoint(x: 330, y: 130)] {
        for source in [false, true] {
          let rect = erEndpointLabelRect(endpoint: endpoint, source: source,
            size: CGSize(width: 190 / scale, height: 25 / scale), obstacles: obstacles,
            gap: max(8, 5 / scale))
          assert(obstacles.allSatisfy { !$0.intersects(rect) })
          obstacles.append(rect)
        }
      }
    }
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

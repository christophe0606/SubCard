// SPDX-License-Identifier: Apache-2.0
#if os(iOS)
import SwiftUI
import UIKit

/// Owns only the canvas touch surface. UIKit supplies the initial two-finger
/// midpoint on iOS 16; a pinch cancels any pending single-finger table drag.
struct ERCanvasTouchInput: UIViewRepresentable {
  let drag: (CGPoint, CGPoint) -> Void
  let end: (CGPoint, CGPoint, Int) -> Void
  let cancel: () -> Void
  let pinch: (UIGestureRecognizer.State, CGPoint, CGFloat) -> Void

  final class TouchView: UIView {
    var input: ERCanvasTouchInput?
    private var dragStart: CGPoint?
    private var pinching = false
    private var suppressDragUntilLift = false
    private lazy var pinchRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(magnify))

    override init(frame: CGRect) {
      super.init(frame: frame)
      isMultipleTouchEnabled = true
      backgroundColor = .clear
      pinchRecognizer.cancelsTouchesInView = false
      addGestureRecognizer(pinchRecognizer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func activeTouches(_ touches: Set<UITouch>, _ event: UIEvent?) -> [UITouch] {
      (event?.allTouches ?? touches).filter {
        $0.view === self && $0.phase != .ended && $0.phase != .cancelled
      }
    }
    private func beginPinch(at point: CGPoint) {
      guard !pinching else { return }
      dragStart = nil
      suppressDragUntilLift = true
      pinching = true
      input?.cancel()
      input?.pinch(.began, point, 1)
    }
    private func finishPinch(_ state: UIGestureRecognizer.State) {
      guard pinching else { return }
      input?.pinch(state, pinchRecognizer.location(in: self), pinchRecognizer.scale)
      pinching = false
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
      let active = activeTouches(touches, event)
      if active.count >= 2 {
        let first = active[0].location(in: self), second = active[1].location(in: self)
        beginPinch(at: CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2))
      } else if !suppressDragUntilLift, !pinching, let touch = active.first {
        let point = touch.location(in: self)
        dragStart = point
        input?.drag(point, point)
      }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
      guard !pinching, !suppressDragUntilLift, let start = dragStart,
        let touch = activeTouches(touches, event).first else { return }
      input?.drag(start, touch.location(in: self))
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
      let remaining = activeTouches(touches, event)
      if pinching && remaining.count < 2 { finishPinch(.ended) }
      if !pinching, !suppressDragUntilLift, let start = dragStart, let touch = touches.first {
        input?.end(start, touch.location(in: self), touch.tapCount)
      }
      dragStart = nil
      if remaining.isEmpty { suppressDragUntilLift = false }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
      finishPinch(.cancelled)
      dragStart = nil
      input?.cancel()
      if activeTouches(touches, event).isEmpty { suppressDragUntilLift = false }
    }
    @objc private func magnify(_ recognizer: UIPinchGestureRecognizer) {
      switch recognizer.state {
      case .began, .changed:
        beginPinch(at: recognizer.location(in: self))
        input?.pinch(.changed, recognizer.location(in: self), recognizer.scale)
      case .ended, .cancelled, .failed:
        finishPinch(recognizer.state)
      default: break
      }
    }
  }

  func makeUIView(context: Context) -> TouchView { TouchView() }
  func updateUIView(_ view: TouchView, context: Context) { view.input = self }
}
#endif

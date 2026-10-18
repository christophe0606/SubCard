// SPDX-License-Identifier: Apache-2.0
import SwiftUI

#if os(macOS)
import AppKit

// SQL is plain code. Disable prose substitutions/checking, and use TextKit 1
// explicitly to avoid NSTextCheckingController stalls in the SwiftUI editor.
struct ERCheckInput: NSViewRepresentable {
  @Binding var text: String
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeNSView(context: Context) -> NSScrollView {
    let storage = NSTextStorage()
    let layout = NSLayoutManager()
    let container = NSTextContainer(containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    storage.addLayoutManager(layout)
    layout.addTextContainer(container)
    let input = NSTextView(frame: .zero, textContainer: container)
    input.isRichText = false
    input.allowsUndo = true
    input.isAutomaticQuoteSubstitutionEnabled = false
    input.isAutomaticDashSubstitutionEnabled = false
    input.isAutomaticTextReplacementEnabled = false
    input.isAutomaticSpellingCorrectionEnabled = false
    input.isContinuousSpellCheckingEnabled = false
    input.isGrammarCheckingEnabled = false
    input.isAutomaticLinkDetectionEnabled = false
    input.isAutomaticDataDetectionEnabled = false
    input.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    input.textContainerInset = NSSize(width: 8, height: 8)
    input.isVerticallyResizable = true
    input.isHorizontallyResizable = false
    input.autoresizingMask = [.width]
    container.widthTracksTextView = true
    input.string = text
    input.delegate = context.coordinator
    input.setAccessibilityLabel("CHECK expression")
    input.setAccessibilityIdentifier("checkExpression")
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.documentView = input
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    context.coordinator.parent = self
    if let input = scroll.documentView as? NSTextView, input.string != text { input.string = text }
  }
  final class Coordinator: NSObject, NSTextViewDelegate {
    var parent: ERCheckInput
    init(_ parent: ERCheckInput) { self.parent = parent }
    func textDidChange(_ notification: Notification) {
      guard let input = notification.object as? NSTextView else { return }
      parent.text = input.string
    }
  }
}
#else
import UIKit

struct ERCheckInput: UIViewRepresentable {
  @Binding var text: String
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  func makeUIView(context: Context) -> UITextView {
    let input = UITextView()
    input.autocapitalizationType = .none
    input.autocorrectionType = .no
    input.spellCheckingType = .no
    input.smartQuotesType = .no
    input.smartDashesType = .no
    input.smartInsertDeleteType = .no
    input.font = UIFontMetrics.default.scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular))
    input.adjustsFontForContentSizeCategory = true
    input.text = text
    input.delegate = context.coordinator
    input.accessibilityLabel = "CHECK expression"
    input.accessibilityIdentifier = "checkExpression"
    return input
  }
  func updateUIView(_ input: UITextView, context: Context) {
    context.coordinator.parent = self
    if input.text != text { input.text = text }
  }
  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: ERCheckInput
    init(_ parent: ERCheckInput) { self.parent = parent }
    func textViewDidChange(_ input: UITextView) { parent.text = input.text }
  }
}
#endif

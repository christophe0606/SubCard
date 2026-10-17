// SPDX-License-Identifier: Apache-2.0
import SubCardCore
import SwiftUI

@main
struct SubCardApp: App {
    var body: some Scene {
        WindowGroup("SubCard") {
            ContentView()
        }
        #if os(macOS)
        .defaultSize(width: 640, height: 400)
        #endif
    }
}

private struct ContentView: View {
    private let greeting = String(cString: subcard_greeting())

    var body: some View {
        Text(greeting)
            .font(.system(size: 32, weight: .medium))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
            #if os(macOS)
            .frame(minWidth: 320, minHeight: 200)
            #endif
    }
}

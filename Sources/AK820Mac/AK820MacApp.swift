import SwiftUI

@main
struct AK820MacApp: App {
    @StateObject private var hid = AK820HIDService()

    var body: some Scene {
        MenuBarExtra("AK820", systemImage: "keyboard") {
            ContentView(hid: hid)
        }
        .menuBarExtraStyle(.window)

    }
}

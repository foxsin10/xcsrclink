import SwiftUI

@main
struct DemoAppApp: App {
    init() {
        // Used by scripts/verify.sh: call every library once under the debugger, then quit.
        if ProcessInfo.processInfo.arguments.contains("-xcsrclink-autorun") {
            print(DemoCalls.staticKit())
            print(DemoCalls.dynamicKit())
            print(DemoCalls.objcKit(OCKCounterBox.shared))
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

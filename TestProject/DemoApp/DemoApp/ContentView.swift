import DynamicKit
import ObjCKit
import StaticKit
import SwiftUI

/// One call into each prebuilt vendor library. Set a breakpoint on a call, then
/// "Step Into" (F7): with xcsrclink linked you land in the library's source under
/// TestProject/VendorSDK instead of assembly.
enum DemoCalls {
    static func staticKit() -> String {
        let greeter = Greeter(name: "xcsrclink")
        return greeter.greeting()                                   // STEP INTO StaticKit
    }

    static func dynamicKit() -> String {
      print("start")
        let value = Calculator.average(of: [3, 5, 7, 9])            // STEP INTO DynamicKit
        return "Average: \(value)"
    }

    static func objcKit(_ box: OCKCounterBox) -> String {
        let count = box.counter.increment()                         // STEP INTO ObjCKit
        return "Count: \(count)"
    }
}

/// Holds the Objective-C counter so its state survives view updates.
final class OCKCounterBox: @unchecked Sendable {
    static let shared = OCKCounterBox()
    let counter = OCKCounter()
}

struct ContentView: View {
    @State private var output = "Tap a button"

    var body: some View {
        NavigationStack {
            List {
                Section("Prebuilt libraries") {
                    Button("StaticKit: Swift static library (.a)") { output = DemoCalls.staticKit() }
                    Button("DynamicKit: Swift dynamic framework + dSYM") { output = DemoCalls.dynamicKit() }
                    Button("ObjCKit: Objective-C static library (.a)") { output = DemoCalls.objcKit(.shared) }
                }
                Section("Result") {
                    Text(output).font(.body.monospaced())
                }
            }
            .navigationTitle("xcsrclink demo")
        }
    }
}

#Preview {
    ContentView()
}

import AppKit

let options = Options.parse(CommandLine.arguments)
if options.stdio {
    StdioBridge.run(port: options.port)
}

let app = NSApplication.shared
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

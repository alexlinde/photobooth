import BoothCore
import AppKit

// PhotoBooth — kiosk photo booth app . See AppOptions.usage for flags.

let options: AppOptions
do {
    options = try AppOptions.parse(CommandLine.arguments)
} catch let e as AppOptions.OptionError {
    if let m = e.message { FileHandle.standardError.write(Data("error: \(m)\n\n".utf8)) }
    print(AppOptions.usage)
    exit(e.message == nil ? 0 : 2)
}

if options.selfTest {
    Task { @MainActor in
        let ok = await BoothScenarios.runAll()
        FileLog.shared.flush()
        exit(ok ? 0 : 1)
    }
    dispatchMain()
}

if options.googleLogin {
    Task { @MainActor in exit(await GoogleLogin.run(configPath: options.configPath)) }
    dispatchMain()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate(options: options)
    app.delegate = delegate
    withExtendedLifetime(delegate) {
        app.run()
    }
}

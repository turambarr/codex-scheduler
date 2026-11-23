import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "authorize" {
    CLI.runDesktopAuthorization()
}
let exitCode = await CLI.run(arguments)
exit(exitCode)

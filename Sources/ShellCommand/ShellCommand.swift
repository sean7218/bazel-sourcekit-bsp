import Foundation

package struct ShellCommand {
    var executable: String
    var currentDir: String
    var args: [String]

    package init(
        executable: String,
        currentDir: String,
        args: [String]
    ) {
        self.executable = executable
        self.currentDir = currentDir
        self.args = args
    }

    package func run() -> (output: String?, error: String?, exitCode: Int32) {
        let task = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        task.standardOutput = outputPipe
        task.standardError = errorPipe
        task.arguments = [executable] + self.args
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.currentDirectoryURL = URL(fileURLWithPath: currentDir)

        do {
            try task.run()

            // Read output BEFORE waiting - this prevents deadlock
            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()

            task.waitUntilExit()

            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outputData, encoding: .utf8) ?? ""
            let error = String(data: errorData, encoding: .utf8) ?? ""

            return (output, error, task.terminationStatus)
        } catch {
            return (nil, "Failed to execute: \(error)", -1)
        }
    }
}


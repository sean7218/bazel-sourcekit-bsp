import ActionQuery
import Foundation
import Logging
import ShellCommand
import SystemPackage

/// Handles Build Server Protocol requests
public class RequestHandler: @unchecked Sendable {
    public let logger: Logger
    public let activityLogger: Logger
    public let config: BuildServerConfig
    public let rootPath: URL
    public let execrootPath: URL

    private let targetsQueue = DispatchQueue(label: "RequestHandler.targets", qos: .userInitiated)
    private var _targets: [BazelTarget] = []

    package var targets: [BazelTarget] {
        get {
            targetsQueue.sync { _targets }
        }
        set {
            targetsQueue.async(flags: .barrier) { [weak self] in
                self?._targets = newValue
            }
        }
    }

    private init(logger: Logger, activityLogger: Logger, config: BuildServerConfig, rootPath: URL, execrootPath: URL) {
        self.logger = logger
        self.activityLogger = activityLogger
        self.config = config
        self.rootPath = rootPath
        self.execrootPath = execrootPath
    }

    /// Initialize the request handler from a build/initialize request
    public static func initialize(request: JSONRPCRequest, logger: Logger, activityLogger: Logger) throws -> RequestHandler {
        guard let params = request.params else {
            throw JSONRPCError.invalidRequest("Missing initialization parameters")
        }

        let buildRequest = try InitializeBuildRequest.from(jsonValue: params)
        let config = try BuildServerConfig.parse(rootUri: buildRequest.rootUri)

        guard let rootPath = URL(string: buildRequest.rootUri) else {
            throw JSONRPCError.invalidRequest("Invalid root URI: \(buildRequest.rootUri)")
        }

        // Get execution root from Bazel
        let execrootPath = try getExecutionRoot(rootPath: rootPath)

        let handler = RequestHandler(
            logger: logger,
            activityLogger: activityLogger,
            config: config,
            rootPath: rootPath,
            execrootPath: execrootPath
        )

        // Load targets
        try handler.loadTargets()

        // TODO: - Log loaded targets for verification

        return handler
    }

    /// Handle a BSP request and return appropriate response
    public func handleRequest(_ request: JSONRPCRequest) throws -> BuildServerResponse {
        switch request.method {
        case "build/initialized":
            return .none

        case "workspace/buildTargets":
            let response = try workspaceBuildTargets(request: request)
            return .response(response)

        case "buildTarget/sources":
            let response = try buildTargetSources(request: request)
            return .response(response)

        case "textDocument/sourceKitOptions":
            let response = try sourceKitOptions(request: request)
            return .response(response)

        case "textDocument/registerForChanges":
            let notification = try registerForChanges(request: request)
            return .notification(notification)

        case "workspace/waitForBuildSystemUpdates":
            let response = try waitForBuildSystemUpdates(request: request)
            return .response(response)

        case "workspace/didChangeWatchedFiles":
            let notification = try didChangeWatchedFiles(request: request)
            return .notification(notification)

        case "buildTarget/prepare":
            let response = try buildTargetPrepare(request: request)
            return .response(response)

        case "buildTarget/didChange":
            return .none

        case "build/shutdown":
            let response = try buildShutdown(request: request)
            return .response(response)

        case "build/exit":
            let notification = try buildExit(request: request)
            return .notification(notification)

        case "window/showMessage":
            return .none

        default:
            return .none
        }
    }

    /// Handle build/initialize request
    public func buildInitialize(request: JSONRPCRequest) throws -> JSONRPCResponse {
        let capabilities = BuildServerCapabilities(
            compileProvider: CompileProvider(languageIds: ["swift"]),
            testProvider: nil,
            runProvider: nil,
            debugProvider: nil,
            inverseSourcesProvider: true,
            dependencySourcesProvider: true,
            resourcesProvider: false,
            outputPathsProvider: false,
            buildTargetChangedProvider: true,
            jvmRunEnvironmentProvider: false,
            jvmTestEnvironmentProvider: false,
            canReload: false
        )

        let computedIndexStorePath = BuildServerConfig.computeIndexStorePath(execrootPath: execrootPath)

        let data = SourceKitInitializeBuildResponseData(
            indexDatabasePath: config.indexDatabasePath,
            indexStorePath: computedIndexStorePath,
            outputPathsProvider: false,
            prepareProvider: true,
            sourceKitOptionsProvider: true,
            defaultSettings: config.defaultSettings ?? []
        )

        let response = InitializeBuildResponse(
            displayName: "Bazel SourceKit BSP",
            version: "1.0.0",
            bspVersion: "2.0.0",
            capabilities: capabilities,
            data: data
        )

        return try JSONRPCResponse(
            id: request.id,
            result: response.toJSONValue()
        )
    }

    // MARK: - BSP Method Implementations

    private func workspaceBuildTargets(request: JSONRPCRequest) throws -> JSONRPCResponse {
        let buildTargets = targets.map { BuildTarget.from(bazelTarget: $0) }
        let response = WorkspaceBuildTargetsResponse(targets: buildTargets)

        return try JSONRPCResponse(
            id: request.id,
            result: response.toJSONValue()
        )
    }

    private func buildTargetSources(request: JSONRPCRequest) throws -> JSONRPCResponse {
        guard let params = request.params else {
            throw JSONRPCError.invalidRequest("Missing parameters")
        }

        let buildTargetSourcesRequest = try BuildTargetSourcesRequest.from(jsonValue: params)
        var items: [SourcesItem] = []

        for target in buildTargetSourcesRequest.targets {
            if let bazelTarget = targets.first(where: { $0.uri == target.uri }) {
                let sources = try getSourcesForTarget(bazelTarget)
                let item = SourcesItem(
                    target: target,
                    sources: sources,
                    roots: [rootPath.absoluteString]
                )
                items.append(item)
            }
        }

        let response = BuildTargetSourcesResponse(items: items)
        return try JSONRPCResponse(
            id: request.id,
            result: response.toJSONValue()
        )
    }

    private func sourceKitOptions(request: JSONRPCRequest) throws -> JSONRPCResponse {
        guard let params = request.params else {
            throw JSONRPCError.invalidRequest("Missing parameters")
        }

        let sourceKitRequest = try TextDocumentSourceKitOptionsRequest.from(jsonValue: params)
        let options = try getSourceKitOptions(for: sourceKitRequest.textDocument.uri, target: sourceKitRequest.target)

        let response = TextDocumentSourceKitOptionsResponse(
            compilerArguments: options,
            workingDirectory: rootPath.path
        )

        return try JSONRPCResponse(
            id: request.id,
            result: response.toJSONValue()
        )
    }

    private func registerForChanges(request: JSONRPCRequest) throws -> JSONRPCNotification {
        guard let params = request.params else {
            throw JSONRPCError.invalidRequest("Missing parameters")
        }

        let registerRequest = try RegisterForChanges.from(jsonValue: params)

        // Find compiler arguments for the specific file
        var options: [String] = []
        for target in targets {
            for inputFile in target.inputFiles {
                if inputFile == registerRequest.uri {
                    options = target.compilerArguments
                    break
                }
            }
            if !options.isEmpty {
                break
            }
        }

        // If no specific options found, use default settings
        if options.isEmpty {
            options = config.defaultSettings ?? []
        }

        let notification = FileOptionsChangedNotification(
            uri: registerRequest.uri,
            updatedOptions: Options(
                options: options,
                workingDirectory: rootPath.path
            )
        )

        return try JSONRPCNotification(
            method: "textDocument/sourceKitOptionsChanged",
            params: notification.toJSONValue()
        )
    }

    private func waitForBuildSystemUpdates(request: JSONRPCRequest) throws -> JSONRPCResponse {
        // For now, just return immediately
        return JSONRPCResponse(
            id: request.id,
            result: .null
        )
    }

    private func didChangeWatchedFiles(request _: JSONRPCRequest) throws -> JSONRPCNotification {
        // Create a proper build target change notification
        // For now, we'll create a generic "changed" event for all loaded targets
        // In a full implementation, this would parse the watched files and determine which targets changed
        var changes: [BuildTargetEvent] = []

        // If we have loaded targets, create change events for them
        if !targets.isEmpty {
            for target in targets {
                let buildTargetIdentifier = BuildTargetIdentifier(uri: target.uri)
                let event = BuildTargetEvent(
                    target: buildTargetIdentifier,
                    kind: .changed,
                    data: BuildTargetEventData()
                )
                changes.append(event)
            }
        } else {
            // If no targets are loaded, we can't determine what changed
            // Create a minimal notification indicating something changed
            // This is better than sending null params
            logger.warning("No targets loaded for buildTarget/didChange notification")
        }

        let notification = BuildTargetDidChangeNotification(changes: changes)

        return try JSONRPCNotification(
            method: "buildTarget/didChange",
            params: notification.toJSONValue()
        )
    }

    private func buildTargetPrepare(request: JSONRPCRequest) throws -> JSONRPCResponse {
        // Build the target using Bazel on a background thread
        invokeBazelBuild()

        // Return immediately without waiting for the build to complete
        return JSONRPCResponse(
            id: request.id,
            result: .null
        )
    }

    private func invokeBazelBuild() {
        var commandArgs = ["build"]
        commandArgs.append(contentsOf: config.targets)
        commandArgs.append(contentsOf: config.aqueryArgs)

        let rootPath = self.rootPath
        let logger = self.logger
        let activityLogger = self.activityLogger

        // Log build invocation to activity logger
        let buildCommand = "bazel " + commandArgs.joined(separator: " ")
        activityLogger.info("Bazel Build: \(buildCommand)")

        Task {
            let result = ShellCommand(
                executable: "bazel",
                currentDir: rootPath.path(),
                args: commandArgs
            ).run()

            if result.exitCode == 0 {
                logger.info("Build completed successfully")
            } else {
                logger.error("Build failed with exit code \(result.exitCode)")
                if let output = result.output {
                    logger.error("Build output: \(output)")
                }
            }
        }
    }

    private func buildShutdown(request: JSONRPCRequest) throws -> JSONRPCResponse {
        return JSONRPCResponse(
            id: request.id,
            result: .null
        )
    }

    private func buildExit(request _: JSONRPCRequest) throws -> JSONRPCNotification {
        return JSONRPCNotification(
            method: "build/exit",
            params: .null
        )
    }

    // MARK: - Helper Methods

    private static func getExecutionRoot(rootPath: URL) throws -> URL {
        guard let output = ShellCommand(
            executable: "bazel",
            currentDir: rootPath.path(),
            args: ["info", "execution_root"]
        ).run().output else {
            fatalError("Failed to get execution_root")
        }

        let execrootPath = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: execrootPath)
    }

    private func loadTargets() throws {
        try ActionQuery().execute(
            targets: config.targets,
            rootPath: rootPath,
            execrootPath: execrootPath,
            aqueryArgs: config.aqueryArgs,
            logger: logger
        ) { [weak self] targets in
            self?.targets = targets
        }
    }

    private func getSourcesForTarget(_ target: BazelTarget) throws -> [SourceItem] {
        // Convert input files to SourceItem objects
        return target.inputFiles.map { filePath in
            SourceItem(
                uri: filePath,
                kind: .file,
                generated: false
            )
        }
    }

    private func getSourceKitOptions(for _: String, target: BuildTargetIdentifier) throws -> [String] {
        // Find the corresponding BazelTarget
        if let bazelTarget = targets.first(where: { $0.uri == target.uri }) {
            return bazelTarget.compilerArguments
        }

        // Return the default settings from config if target not found
        return config.defaultSettings ?? []
    }
}

// MARK: - BuildServerResponse enum

public enum BuildServerResponse {
    case response(JSONRPCResponse)
    case notification(JSONRPCNotification)
    case none
    case exit
}

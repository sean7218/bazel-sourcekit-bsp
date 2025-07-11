import BSPError
import Foundation
import Logging
import ShellCommand

// MARK: - Cache Structures

private struct BazelTargetsCache: Codable {
    var entries: [String: CacheEntry] = [:]

    struct CacheEntry: Codable {
        let targets: [BazelTarget]
        let timestamp: Date
    }
}

// MARK: - Bazel Query Functions

package struct ActionQuery: Sendable {
    private static let cacheFileName = "bazel-targets-cache.json"
    private static let cacheQueue = DispatchQueue(label: "bazel.cache.queue", qos: .utility)

    package init() {}

    /// Executes Bazel aquery and returns processed targets
    package func execute(
        targets: [String],
        rootPath: URL,
        execrootPath: URL,
        aqueryArgs: [String],
        logger: Logger,
        completion: @escaping @Sendable ([BazelTarget]) -> Void
    ) throws {
        let cacheKey = generateCacheKey(targets: targets)
        let cacheFilePath = getBSPCachePath(rootPath: rootPath)

        // Try to load from cache first
        if let cachedTargets = loadFromCache(cacheKey: cacheKey, cacheFilePath: cacheFilePath, logger: logger) {
            logger.info("Cache hit for targets: \(targets). Returning cached results and refreshing in background.")

            // Return cached results immediately
            completion(cachedTargets)

            // Kick off background refresh
            Task {
                do {
                    let queryResult = try processAquery(
                        targets: targets,
                        rootPath: rootPath,
                        aqueryArgs: aqueryArgs,
                        logger: logger
                    )

                    let freshResult = try processBazelTargets(
                        queryResult: queryResult,
                        rootPath: rootPath,
                        execrootPath: execrootPath,
                        logger: logger
                    )

                    // Save to cache
                    saveToCache(
                        cacheKey: cacheKey,
                        targets: freshResult,
                        cacheFilePath: cacheFilePath,
                        logger: logger
                    )

                    // Only call completion again if results are different
                    if !arraysEqual(cachedTargets, freshResult) {
                        logger.info("Fresh results differ from cache. Calling completion with updated results.")
                        completion(freshResult)
                    } else {
                        logger.info("Fresh results match cache. No additional completion call needed.")
                    }
                } catch {
                    logger.error("Background refresh failed: \(error)")
                }
            }
        } else {
            // No cache, process normally
            logger.info("Cache miss for targets: \(targets). Processing fresh data.")

            let queryResult = try processAquery(
                targets: targets,
                rootPath: rootPath,
                aqueryArgs: aqueryArgs,
                logger: logger
            )

            let result = try processBazelTargets(
                queryResult: queryResult,
                rootPath: rootPath,
                execrootPath: execrootPath,
                logger: logger
            )

            // Save to cache
            saveToCache(
                cacheKey: cacheKey,
                targets: result,
                cacheFilePath: cacheFilePath,
                logger: logger
            )

            completion(result)
        }
    }

    // MARK: - Cache Helper Methods

    private func generateCacheKey(targets: [String]) -> String {
        return targets.sorted().joined(separator: "|")
    }

    private func getBSPCachePath(rootPath _: URL) -> URL {
        let bspDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".bazel-sourcekit-bsp")

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: bspDir, withIntermediateDirectories: true)

        return bspDir.appendingPathComponent(Self.cacheFileName)
    }

    private func loadFromCache(cacheKey: String, cacheFilePath: URL, logger: Logger) -> [BazelTarget]? {
        guard FileManager.default.fileExists(atPath: cacheFilePath.path) else {
            logger.debug("BSP cache file does not exist: \(cacheFilePath.path)")
            return nil
        }

        do {
            let data = try Data(contentsOf: cacheFilePath)
            let cache = try JSONDecoder().decode(BazelTargetsCache.self, from: data)

            if let entry = cache.entries[cacheKey] {
                logger.info("Loaded \(entry.targets.count) targets from cache for key: \(cacheKey)")
                return entry.targets
            } else {
                logger.debug("No cache entry found for key: \(cacheKey)")
                return nil
            }
        } catch {
            logger.error("Failed to load cache: \(error)")
            return nil
        }
    }

    private func saveToCache(cacheKey: String, targets: [BazelTarget], cacheFilePath: URL, logger: Logger) {
        Self.cacheQueue.async {
            do {
                var cache: BazelTargetsCache

                // Load existing cache or create new one
                if FileManager.default.fileExists(atPath: cacheFilePath.path) {
                    let data = try Data(contentsOf: cacheFilePath)
                    cache = try JSONDecoder().decode(BazelTargetsCache.self, from: data)
                } else {
                    cache = BazelTargetsCache()
                }

                // Update cache entry
                cache.entries[cacheKey] = BazelTargetsCache.CacheEntry(
                    targets: targets,
                    timestamp: Date()
                )

                // Save to file
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                let data = try encoder.encode(cache)
                try data.write(to: cacheFilePath)

                logger.info("Saved \(targets.count) targets to BSP cache for key: \(cacheKey)")
            } catch {
                logger.error("Failed to save cache: \(error)")
            }
        }
    }

    private func arraysEqual(_ lhs: [BazelTarget], _ rhs: [BazelTarget]) -> Bool {
        guard lhs.count == rhs.count else { return false }

        let lhsSet = Set(lhs)
        let rhsSet = Set(rhs)
        return lhsSet == rhsSet
    }

    // MARK: - Processing Methods

    private func processAquery(
        targets: [String],
        rootPath: URL,
        aqueryArgs: [String],
        logger: Logger
    ) throws -> QueryResult {
        // Generate combined mnemonic query for multiple targets using set()
        let targetSet = targets.joined(separator: " ")
        let mnemonic = "mnemonic(\"SwiftCompile|ObjcCompile\", deps(set(\(targetSet))))"

        var commandArgs: [String] = [
            "aquery",
            mnemonic,
            "--output=jsonproto",
        ]
        commandArgs.append(contentsOf: aqueryArgs)

        logger.info("Running aquery with mnemonic: \(mnemonic)")

        let (output, error, status) = ShellCommand(
            executable: "bazel",
            currentDir: rootPath.path(),
            args: commandArgs,
        ).run()

        guard let output = output, output != "" else {
            throw BSPError.custom(
                """
                ActionQuery output is empty string!
                Error: \(String(describing: error))
                Exit Code: \(status)
                Current Directory: \(rootPath.path())
                """
            )
        }

        return try parseQueryResult(output: output)
    }

    /// Parses Bazel aquery JSON proto output
    func parseQueryResult(output: String) throws -> QueryResult {
        guard let data = output.data(using: .utf8) else {
            throw BSPError.bazelError("Failed to convert aquery output to UTF-8 data")
        }

        guard !data.isEmpty else {
            throw BSPError.custom("QueryResult output is empty")
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(QueryResult.self, from: data)
        } catch {
            let jsonError = error.localizedDescription
            throw BSPError.custom("ActionQuery JSON parsing failed: \(jsonError). Data size: \(data.count) bytes")
        }
    }

    /// Processes the query result into BazelTarget objects
    func processBazelTargets(
        queryResult: QueryResult,
        rootPath: URL,
        execrootPath: URL,
        logger: Logger,
    ) throws -> [BazelTarget] {
        // Convert arrays to hashmaps for efficient lookup
        let artifacts = Dictionary(uniqueKeysWithValues: queryResult.artifacts.map { ($0.id, $0) })
        let files = Dictionary(uniqueKeysWithValues: queryResult.depSetOfFiles.map { ($0.id, $0) })
        let fragments = Dictionary(
            uniqueKeysWithValues: queryResult.pathFragments.map { ($0.id, $0) })

        nonisolated(unsafe) var bazelTargets: [BazelTarget] = []
        let lock = NSLock()
        nonisolated(unsafe) var processedCount = 0
        let totalCount = queryResult.actions.count

        logger.info("Processing \(totalCount) actions in parallel")

        DispatchQueue.concurrentPerform(iterations: totalCount) { index in
            let action = queryResult.actions[index]

            do {
                let inputFiles = try buildInputFiles(
                    artifacts: artifacts,
                    files: files,
                    fragments: fragments,
                    action: action,
                    rootPath: rootPath
                )

                let sdk = try selectAppleSDK(action)

                let compilerArguments = try processCompilerArguments(
                    action: action,
                    execrootPath: execrootPath,
                    sdk: sdk
                )

                guard let target = queryResult.targets.first(where: { $0.id == action.targetId })
                else {
                    logger.warning("Target not found for action: \(action.targetId)")
                    return
                }

                let uri = try bazelToUri(rootPath: rootPath, label: target.label, id: target.id)

                let bazelTarget = BazelTarget(
                    id: action.targetId,
                    uri: uri,
                    label: target.label,
                    kind: "swift_library", // TODO: Get from rule class
                    tags: [],
                    inputFiles: inputFiles,
                    compilerArguments: compilerArguments
                )

                lock.lock()
                bazelTargets.append(bazelTarget)
                processedCount += 1

                // Log progress every 10 actions or for the last action
                let currentCount = processedCount
                lock.unlock()

                if currentCount % 10 == 0 || currentCount == totalCount {
                    logger.info("Processed \(currentCount)/\(totalCount) actions")
                }

            } catch {
                logger.error("Error processing action \(index + 1): \(error)")
            }
        }

        // Deduplicate targets
        let uniqueTargets = Array(Set(bazelTargets))
        return uniqueTargets
    }

    /// Builds input files from artifacts
    private func buildInputFiles(
        artifacts: [UInt32: Artifact],
        files: [UInt32: DepSetOfFiles],
        fragments: [UInt32: PathFragment],
        action: Action,
        rootPath: URL,
    ) throws -> [String] {
        var inputFiles: [String] = []
        var validPaths: [String] = []
        var invalidPaths: [String] = []

        for depSetId in action.inputDepSetIds {
            let artifactIds = buildArtifactIds(fileSet: files[depSetId], files: files)

            for artifactId in artifactIds {
                guard let artifact = artifacts[artifactId] else { continue }

                let filePath = buildFilePath(fragments: fragments, leafId: artifact.pathFragmentId)

                // Convert to URL and filter for Swift and Objc files
                // TODO: change external/ to execution_root/external
                let fullPath = rootPath.appendingPathComponent(filePath)
                if fullPath.pathExtension == "swift" || fullPath.pathExtension == "m" || fullPath.pathExtension == "h" {
                    // Check if file exists
                    let fileExists = FileManager.default.fileExists(atPath: fullPath.path)

                    if fileExists {
                        inputFiles.append(fullPath.absoluteString)
                        validPaths.append(fullPath.path)
                    } else {
                        // TODO: check all invalidPaths and log to user
                        invalidPaths.append(fullPath.path)
                    }
                }
            }
        }

        return inputFiles
    }

    /// Recursively builds artifact IDs from dep sets
    func buildArtifactIds(fileSet: DepSetOfFiles?, files: [UInt32: DepSetOfFiles])
        -> [UInt32]
    {
        guard let fileSet = fileSet else { return [] }

        var artifactIds: [UInt32] = []

        // Add direct artifacts
        if let directIds = fileSet.directArtifactIds {
            artifactIds.append(contentsOf: directIds)
        }

        // Add transitive artifacts
        if let transitiveIds = fileSet.transitiveDepSetIds {
            for transitiveId in transitiveIds {
                let transitiveIds = buildArtifactIds(fileSet: files[transitiveId], files: files)
                artifactIds.append(contentsOf: transitiveIds)
            }
        }

        return artifactIds
    }

    /// Builds file path from fragments all file paths are relative to the project root
    func buildFilePath(fragments: [UInt32: PathFragment], leafId: UInt32) -> String {
        guard let leaf = fragments[leafId] else { return "" }

        if let parentId = leaf.parentId {
            let parentPath = buildFilePath(fragments: fragments, leafId: parentId)
            return parentPath + "/" + leaf.label
        } else {
            return leaf.label
        }
    }

    /// Getting default Apple SDKs, some targets such as Swift macros needs MacOSX.sdk
    /// but UIKit/SwiftUI targets needs iPhoneSimulator.sdk.
    /// TODO: Enable users specify the actual SDK instead of using the default
    func selectAppleSDK(_ action: Action) throws -> String {
        let applePlatform = action.environmentVariables.first {
            $0.key == "APPLE_SDK_PLATFORM"
        }

        guard let applePlatform = applePlatform?.value else {
            throw BSPError.custom(
                "Can't determine AppleSDK. Target should be either iPhoneSimulator.sdk or MacOSX.sdk"
            )
        }

        if applePlatform == "iPhoneSimulator" {
            return
                "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator.sdk"
        } else {
            return
                "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
        }
    }

    /// Processes compiler arguments with transformations
    func processCompilerArguments(
        action: Action,
        execrootPath: URL,
        sdk: String
    ) throws -> [String] {
        var compilerArguments: [String] = []
        var validArgPaths: [String] = []
        var invalidArgPaths: [String] = []

        var index = 0
        let count = action.arguments.count

        while index < count {
            let arg = action.arguments[index]

            // Skip swiftc executable and wrapper arguments
            if arg.contains("-Xwrapped-swift") || arg.hasSuffix("worker") || arg.hasPrefix("swiftc") {
                index += 1
                continue
            }

            // skip clang
            if arg.contains("wrapped_clang") {
                index += 1
                continue
            }

            if arg.contains("__BAZEL_EXECUTION_ROOT__") {
                let transformedArg = arg.replacingOccurrences(
                    of: "__BAZEL_EXECUTION_ROOT__",
                    with: execrootPath.absoluteString
                )
                compilerArguments.append(transformedArg)
                index += 1
                continue
            }

            // Skip batch mode (incompatible with -index-file)
            if arg.contains("-enable-batch-mode") {
                index += 1
                continue
            }

            // Skip index store path arguments
            if arg.contains("-index-store-path") {
                if index + 1 < count, action.arguments[index + 1].contains("indexstore") {
                    index += 2
                    continue
                }
            }

            // Skip const-gather-protocols arguments
            if arg.contains("-Xfrontend"), index + 1 < count {
                let nextArg = action.arguments[index + 1]
                if nextArg.contains("-const-gather-protocols-file")
                    || nextArg.contains("const_protocols_to_gather.json")
                {
                    index += 2
                    continue
                }
            }

            // Replace SDK placeholder
            if arg.contains("__BAZEL_XCODE_SDKROOT__") {
                let transformedArg = arg.replacingOccurrences(
                    of: "__BAZEL_XCODE_SDKROOT__",
                    with: sdk
                )
                validateArgumentPath(
                    arg: transformedArg,
                    validPaths: &validArgPaths,
                    invalidPaths: &invalidArgPaths
                )
                compilerArguments.append(transformedArg)
                index += 1
                continue
            }

            // replace Xcode Developer Directory
            if arg.contains("__BAZEL_XCODE_DEVELOPER_DIR__/") {
                let transformedArg = arg.replacingOccurrences(
                    of: "__BAZEL_XCODE_DEVELOPER_DIR__/",
                    with: "/Applications/Xcode.app/Contents/Developer/"
                )
                compilerArguments.append(transformedArg)
                index += 1
                continue
            }

            // Transform bazel-out/ paths
            if arg.contains("bazel-out/") {
                let _prefix = "\(execrootPath.path)/bazel-out/"
                let transformedArg = arg.replacingOccurrences(of: "bazel-out/", with: _prefix)
                validateArgumentPath(
                    arg: transformedArg,
                    validPaths: &validArgPaths,
                    invalidPaths: &invalidArgPaths
                )
                compilerArguments.append(transformedArg)
                index += 1
                continue
            }

            // Transform external/ paths
            if arg.contains("external/") {
                let _prefix = "\(execrootPath.path)/external/"
                let transformedArg = arg.replacingOccurrences(of: "external/", with: _prefix)
                validateArgumentPath(
                    arg: transformedArg,
                    validPaths: &validArgPaths,
                    invalidPaths: &invalidArgPaths
                )
                compilerArguments.append(transformedArg)
                index += 1
                continue
            }

            validateArgumentPath(
                arg: arg,
                validPaths: &validArgPaths,
                invalidPaths: &invalidArgPaths
            )
            compilerArguments.append(arg)
            index += 1
        }

        // TODO: Check invalidArgPaths and log to users
        return compilerArguments
    }

    /// Validates paths in compiler arguments
    private func validateArgumentPath(
        arg: String,
        validPaths: inout [String],
        invalidPaths: inout [String]
    ) {
        // Check if argument looks like a file path (contains / and doesn't start with -)
        if arg.contains("/") && !arg.hasPrefix("-") {
            let fileExists = FileManager.default.fileExists(atPath: arg)
            if fileExists {
                validPaths.append(arg)
            } else {
                invalidPaths.append(arg)
            }
        }
        // Check for -I and -F flag paths
        else if arg.hasPrefix("-I") || arg.hasPrefix("-F") {
            let pathPart = String(arg.dropFirst(2))
            if !pathPart.isEmpty {
                let fileExists = FileManager.default.fileExists(atPath: pathPart)
                if fileExists {
                    validPaths.append(pathPart)
                } else {
                    invalidPaths.append(pathPart)
                }
            }
        }
    }

    /// Converts Bazel label to URI
    private func bazelToUri(rootPath _: URL, label: String, id: UInt32) throws -> String {
        // Simple implementation - in practice you might want more sophisticated URI generation
        return "bazel://\(label)#\(id)"
    }
}

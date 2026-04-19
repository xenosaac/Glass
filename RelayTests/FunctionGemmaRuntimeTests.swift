import XCTest
@testable import Relay

final class FunctionGemmaRuntimeTests: XCTestCase {

 override func tearDown() async throws {
 try? FileManager.default.removeItem(at: AppPaths.hydratedFunctionGemmaModel)
 }

 func test_functionGemmaPaths_useDedicatedDirectoryNames() {
 XCTAssertEqual(AppPaths.functionGemmaModel.lastPathComponent, "functiongemma-270m-it")
 XCTAssertEqual(AppPaths.hydratedFunctionGemmaModel.lastPathComponent, "functiongemma-270m-it")
 }

 func test_prepareFunctionGemmaForLoad_prefersHydratedModelWhenPresent() async throws {
 try AppPaths.createIfNeeded
 try FileManager.default.createDirectory(
 at: AppPaths.hydratedFunctionGemmaModel,
 withIntermediateDirectories: true
 )
 let configURL = AppPaths.hydratedFunctionGemmaModel.appendingPathComponent("config.txt")
 try Data("ready".utf8).write(to: configURL)

 let resolved = try await AppPaths.prepareFunctionGemmaForLoad

 XCTAssertEqual(resolved?.source, .hydratedBundle)
 XCTAssertEqual(resolved?.url, AppPaths.hydratedFunctionGemmaModel)
 }

 func test_sharedFunctionGemmaRuntime_startsWithoutFailureReason() async {
 let runtime = SharedFunctionGemmaRuntime
 let reason = await runtime.lastFailureReason
 XCTAssertNil(reason)
 }
}

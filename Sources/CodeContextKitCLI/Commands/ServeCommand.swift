import ArgumentParser
import CodeContextKitServer
import CodeContextKitRetrieval
import Foundation

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Starts a local web server for the visualizer."
    )

    @Option(name: .shortAndLong, help: "The port to run the server on.")
    var port: Int?

    func run() async throws {
        do {
            try WaxEmbedderIdentity.requireCurrent()
        } catch {
            print("Error: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        let finalPort: Int
        if let port = self.port {
            finalPort = port
        } else if let freePort = CodeContextServer.findFreePort() {
            finalPort = freePort
        } else {
            finalPort = 8080 // Fallback
        }

        print("Starting server on port \(finalPort)...")
        let url = "http://localhost:\(finalPort)"
        
        // Open browser in background after a short delay
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s delay
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = [url]
            try? process.run()
        }

        let server = CodeContextServer(port: finalPort)
        try await server.run()
    }
}

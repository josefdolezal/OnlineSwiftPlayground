import BuildToolchainEngine
import TSCBasic
import Vapor

public final class TerminalService {

    private let buildToolchain: BuildToolchain = .init()
    private var connections: [WebSocket] = []
    private let workingDirectory: AbsolutePath

    private lazy var timer: DispatchSourceTimer = {
        let t = DispatchSource.makeTimerSource()
        t.schedule(deadline: DispatchTime.now() + 5, repeating: 30)
        t.setEventHandler(handler: DispatchWorkItem(block: { [weak self] in
            self?.connections.forEach { connection in
                connection.sendPing()
            }
        }))
        return t
    }()

    init(workingDirectory: String) {
        self.workingDirectory = AbsolutePath(workingDirectory)

        timer.resume()
    }

    public func connected(on webSocket: WebSocket) {
        webSocket.onBinary(received(on:bytes:))
        webSocket.onText(received(on:text:))
        webSocket.onClose.whenComplete { [weak webSocket] _ in
            webSocket.map(self.disconnected(on:))
        }

        connections.append(webSocket)
    }

    private func received(on webSocket: WebSocket, bytes: ByteBuffer) {
        _ = webSocket.close(code: .unacceptableData)
        close(webSocket: webSocket)
    }

    private func received(on webSocket: WebSocket, text: String) {
        guard
            let data = text.data(using: .utf8),
            let command = try? JSONDecoder().decode(Command.self, from: data)
        else {
            _ = webSocket.close(code: .unexpectedServerError)
            close(webSocket: webSocket)
            return
        }

        switch command {
        case .run(let sourceCode, let toolchain):
            if
                let result = run(codeText: sourceCode, toolchain: toolchain),
                let responseJSON = try? JSONEncoder().encode(Command.output(result.text, result.annotations ?? [])),
                let responseString = String(data: responseJSON, encoding: .utf8)
            {
                webSocket.send(responseString)
            }
        default:
            break
        }
    }

    private func disconnected(on webSocket: WebSocket) {
        close(webSocket: webSocket)
    }

    private func close(webSocket: WebSocket) {
        connections.removeAll { $0 === webSocket }
    }
}

private struct RunResult {
    let text: String
    let annotations: [Annotation]?
}

private extension TerminalService {
    private func run(codeText: String, toolchain: SwiftToolchain) -> RunResult? {
        do {
            let buildResult = try buildToolchain.build(code: codeText, toolchain: toolchain, root: workingDirectory)
            let runResult = try buildToolchain.run(binaryPath: buildResult.get())
            return RunResult(text: try runResult.get(), annotations: nil)
        } catch BuildToolchain.Error.failed(let output) {
            let items = try? SwiftcOutputParser().parse(input: output)
            return RunResult(text: output, annotations: items)
        } catch {
            return RunResult(text: error.localizedDescription, annotations: nil)
        }
    }
}

private enum TerminalServiceKey: StorageKey {
    typealias Value = TerminalService
}

public extension Request {
    var terminal: TerminalService {
        get {
            guard let service = storage[TerminalServiceKey.self] else {
                let newService = TerminalService(workingDirectory: application.directory.workingDirectory)
                storage[TerminalServiceKey.self] = newService
                return newService
            }
            return service
        }
        set {
            storage[TerminalServiceKey.self] = newValue
        }
    }
}

import Foundation
import NIO
import NIOHTTP1

// MARK: - HTTPRequestAccumulator
// Buffers head + body parts into a single (HTTPRequestHead, Data) tuple.

final class HTTPRequestAccumulator: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn  = HTTPServerRequestPart
    typealias InboundOut = (head: HTTPRequestHead, body: Data)

    private var pendingHead: HTTPRequestHead?
    private var bodyData = Data()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            pendingHead = h
            bodyData = Data()
        case .body(var buf):
            if let bytes = buf.readBytes(length: buf.readableBytes) {
                bodyData.append(contentsOf: bytes)
            }
        case .end:
            guard let h = pendingHead else { return }
            context.fireChannelRead(wrapInboundOut((head: h, body: bodyData)))
            pendingHead = nil
            bodyData = Data()
        }
    }
}

// MARK: - NateBotHTTPHandler

final class NateBotHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = (head: HTTPRequestHead, body: Data)

    private let router: WebRouter

    init(router: WebRouter) {
        self.router = router
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let req     = unwrapInboundIn(data)
        let channel = context.channel

        router.handle(head: req.head, body: req.body) { statusCode, headers, body in
            channel.eventLoop.execute {
                var responseHead = HTTPResponseHead(
                    version: req.head.version,
                    status: HTTPResponseStatus(statusCode: statusCode)
                )
                for (name, value) in headers {
                    responseHead.headers.replaceOrAdd(name: name, value: value)
                }
                responseHead.headers.replaceOrAdd(name: "content-length", value: "\(body.count)")
                responseHead.headers.replaceOrAdd(name: "connection", value: "close")

                var buf = channel.allocator.buffer(capacity: body.count)
                buf.writeBytes(body)

                channel.write(HTTPServerResponsePart.head(responseHead), promise: nil)
                channel.write(HTTPServerResponsePart.body(.byteBuffer(buf)), promise: nil)
                channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in
                    channel.close(promise: nil)
                }
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

// MARK: - WebServer

final class WebServer {
    private let router: WebRouter
    private var serverChannel: Channel?
    private let group: MultiThreadedEventLoopGroup

    init(router: WebRouter) {
        self.router = router
        self.group  = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    func start(host: String = "127.0.0.1", port: Int) {
        let router = self.router
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true)
                    .flatMap { channel.pipeline.addHandler(HTTPRequestAccumulator()) }
                    .flatMap { channel.pipeline.addHandler(NateBotHTTPHandler(router: router)) }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)

        do {
            let channel = try bootstrap.bind(host: host, port: port).wait()
            serverChannel = channel
            print("[NateBot] Web UI available at http://\(host):\(port)")
        } catch {
            print("[NateBot] ERROR: Could not start web server on port \(port): \(error)")
        }
    }

    func stop() {
        try? serverChannel?.close().wait()
        try? group.syncShutdownGracefully()
    }
}

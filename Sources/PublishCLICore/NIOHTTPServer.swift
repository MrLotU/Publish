//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2017-2018 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIO
import NIOHTTP1

extension String {
    func chopPrefix(_ prefix: String) -> String? {
        if self.unicodeScalars.starts(with: prefix.unicodeScalars) {
            return String(self[self.index(self.startIndex, offsetBy: prefix.count)...])
        } else {
            return nil
        }
    }

    func containsDotDot() -> Bool {
        for idx in self.indices {
            if self[idx] == "." && idx < self.index(before: self.endIndex) && self[self.index(after: idx)] == "." {
                return true
            }
        }
        return false
    }
}

private func httpResponseHead(request: HTTPRequestHead, status: HTTPResponseStatus, headers: HTTPHeaders = HTTPHeaders()) -> HTTPResponseHead {
    var head = HTTPResponseHead(version: request.version, status: status, headers: headers)
    let connectionHeaders: [String] = head.headers[canonicalForm: "connection"].map { $0.lowercased() }

    if !connectionHeaders.contains("keep-alive") && !connectionHeaders.contains("close") {
        // the user hasn't pre-set either 'keep-alive' or 'close', so we might need to add headers
        switch (request.isKeepAlive, request.version.major, request.version.minor) {
        case (true, 1, 0):
            // HTTP/1.0 and the request has 'Connection: keep-alive', we should mirror that
            head.headers.add(name: "Connection", value: "keep-alive")
        case (false, 1, let n) where n >= 1:
            // HTTP/1.1 (or treated as such) and the request has 'Connection: close', we should mirror that
            head.headers.add(name: "Connection", value: "close")
        default:
            // we should match the default or are dealing with some HTTP that we don't support, let's leave as is
            ()
        }
    }
    return head
}

private final class HTTPHandler: ChannelInboundHandler {
    private enum FileIOMethod {
        case sendfile
        case nonblockingFileIO
    }
    public typealias InboundIn = HTTPServerRequestPart
    public typealias OutboundOut = HTTPServerResponsePart

    private enum State {
        case idle
        case waitingForRequestBody
        case sendingResponse

        mutating func requestReceived() {
            precondition(self == .idle, "Invalid state for request received: \(self)")
            self = .waitingForRequestBody
        }

        mutating func requestComplete() {
            precondition(self == .waitingForRequestBody, "Invalid state for request complete: \(self)")
            self = .sendingResponse
        }

        mutating func responseComplete() {
            precondition(self == .sendingResponse, "Invalid state for response complete: \(self)")
            self = .idle
        }
    }

    private var buffer: ByteBuffer! = nil
    private var keepAlive = false
    private var state = State.idle
    private let htdocsPath: String

    private var infoSavedRequestHead: HTTPRequestHead?
    private var infoSavedBodyBytes: Int = 0

    private var handler: ((ChannelHandlerContext, HTTPServerRequestPart) -> Void)?
    private let fileIO: NonBlockingFileIO

    public init(fileIO: NonBlockingFileIO, htdocsPath: String) {
        self.htdocsPath = htdocsPath
        self.fileIO = fileIO
    }

    private func handleFile(context: ChannelHandlerContext, request: HTTPServerRequestPart, path _path: String) {
        self.buffer.clear()

        func sendErrorResponse(request: HTTPRequestHead, _ error: Error) {
            var body = context.channel.allocator.buffer(capacity: 128)
            let response = { () -> HTTPResponseHead in
                switch error {
                case let e as IOError where e.errnoCode == ENOENT:
                    body.writeStaticString("IOError (not found)\r\n")
                    return httpResponseHead(request: request, status: .notFound)
                case let e as IOError:
                    body.writeStaticString("IOError (other)\r\n")
                    body.writeString(e.description)
                    body.writeStaticString("\r\n")
                    return httpResponseHead(request: request, status: .notFound)
                default:
                    body.writeString("\(type(of: error)) error\r\n")
                    return httpResponseHead(request: request, status: .internalServerError)
                }
            }()
            body.writeString("\(error)")
            body.writeStaticString("\r\n")
            context.write(self.wrapOutboundOut(.head(response)), promise: nil)
            context.write(self.wrapOutboundOut(.body(.byteBuffer(body))), promise: nil)
            context.writeAndFlush(self.wrapOutboundOut(.end(nil)), promise: nil)
            context.channel.close(promise: nil)
        }

        func responseHead(request: HTTPRequestHead, fileRegion region: FileRegion, path: String) -> HTTPResponseHead {
            var response = httpResponseHead(request: request, status: .ok)
            response.headers.add(name: "Content-Length", value: "\(region.endIndex)")
            response.headers.add(name: "Content-Type", value: fileExtensionMediaTypeMapping[String(path.split(separator: ".").last ?? "txt")]!)
            return response
        }

        switch request {
        case .head(let request):
            self.keepAlive = request.isKeepAlive
            self.state.requestReceived()
            guard !request.uri.containsDotDot() else {
                let response = httpResponseHead(request: request, status: .forbidden)
                context.write(self.wrapOutboundOut(.head(response)), promise: nil)
                self.completeResponse(context, trailers: nil, promise: nil)
                return
            }
            var path = self.htdocsPath + (_path.chopPrefix("/") ?? _path)
            if path.last?.unicodeScalars.starts(with: "/".unicodeScalars) ?? true {
                path += "index.html"
            }
            if !path.contains(".") {
                path += "/index.html"
            }
            let fileHandleAndRegion = self.fileIO.openFile(path: path, eventLoop: context.eventLoop)
            fileHandleAndRegion.whenFailure {
                sendErrorResponse(request: request, $0)
            }
            fileHandleAndRegion.whenSuccess { (file, region) in
                var responseStarted = false
                let response = responseHead(request: request, fileRegion: region, path: path)
                if region.readableBytes == 0 {
                    responseStarted = true
                    context.write(self.wrapOutboundOut(.head(response)), promise: nil)
                }
                return self.fileIO.readChunked(fileRegion: region,
                                               chunkSize: 32 * 1024,
                                               allocator: context.channel.allocator,
                                               eventLoop: context.eventLoop) { buffer in
                                                if !responseStarted {
                                                    responseStarted = true
                                                    context.write(self.wrapOutboundOut(.head(response)), promise: nil)
                                                }
                                                return context.writeAndFlush(self.wrapOutboundOut(.body(.byteBuffer(buffer))))
                }.flatMap { () -> EventLoopFuture<Void> in
                    let p = context.eventLoop.makePromise(of: Void.self)
                    self.completeResponse(context, trailers: nil, promise: p)
                    return p.futureResult
                }.flatMapError { error in
                    if !responseStarted {
                        let response = httpResponseHead(request: request, status: .ok)
                        context.write(self.wrapOutboundOut(.head(response)), promise: nil)
                        var buffer = context.channel.allocator.buffer(capacity: 100)
                        buffer.writeString("fail: \(error), \(path)")
                        context.write(self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                        self.state.responseComplete()
                        return context.writeAndFlush(self.wrapOutboundOut(.end(nil)))
                    } else {
                        return context.close()
                    }
                }.whenComplete { (_: Result<Void, Error>) in
                    _ = try? file.close()
                }
            }
        case .end:
            self.state.requestComplete()
        default:
            fatalError("oh noes: \(request)")
        }
    }

    private func completeResponse(_ context: ChannelHandlerContext, trailers: HTTPHeaders?, promise: EventLoopPromise<Void>?) {
        self.state.responseComplete()

        let promise = self.keepAlive ? promise : (promise ?? context.eventLoop.makePromise())
        if !self.keepAlive {
            promise!.futureResult.whenComplete { (_: Result<Void, Error>) in context.close(promise: nil) }
        }
        self.handler = nil

        context.writeAndFlush(self.wrapOutboundOut(.end(trailers)), promise: promise)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = self.unwrapInboundIn(data)
        if let handler = self.handler {
            handler(context, reqPart)
            return
        }

        switch reqPart {
        case .head(let request):
            self.handler = { self.handleFile(context: $0, request: $1, path: request.uri) }
            self.handler!(context, reqPart)
        case .body:
            break
        case .end:
            self.state.requestComplete()
            let content = HTTPServerResponsePart.body(.byteBuffer(buffer!.slice()))
            context.write(self.wrapOutboundOut(content), promise: nil)
            self.completeResponse(context, trailers: nil, promise: nil)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.buffer = context.channel.allocator.buffer(capacity: 0)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let evt as ChannelEvent where evt == ChannelEvent.inputClosed:
            // The remote peer half-closed the channel. At this time, any
            // outstanding response will now get the channel closed, and
            // if we are idle or waiting for a request body to finish we
            // will close the channel immediately.
            switch self.state {
            case .idle, .waitingForRequestBody:
                context.close(promise: nil)
            case .sendingResponse:
                self.keepAlive = false
            }
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }
}

func serveServer(on port: Int, from path: String) throws {
    let htdocs = path

    let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    let threadPool = NIOThreadPool(numberOfThreads: 6)
    threadPool.start()

    let fileIO = NonBlockingFileIO(threadPool: threadPool)
    
    func childChannelInitializer(channel: Channel) -> EventLoopFuture<Void> {
        return channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
            channel.pipeline.addHandler(HTTPHandler(fileIO: fileIO, htdocsPath: htdocs))
        }
    }

    let socketBootstrap = ServerBootstrap(group: group)
        // Specify backlog and enable SO_REUSEADDR for the server itself
        .serverChannelOption(ChannelOptions.backlog, value: 256)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        // Set the handlers that are applied to the accepted Channels
        .childChannelInitializer(childChannelInitializer(channel:))

        // Enable SO_REUSEADDR for the accepted Channels
        .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

    defer {
        try! group.syncShutdownGracefully()
        try! threadPool.syncShutdownGracefully()
    }

    let channel = try socketBootstrap.bind(host: "::1", port: port).wait()
    
    guard channel.localAddress != nil else {
        fatalError("Address was unable to bind. Please check that the socket was not closed or that the address family was understood.")
    }
    print("""
    🌍 Starting web server at http://localhost:\(port)
    """)

    // This will never unblock as we don't close the ServerChannel
    try channel.closeFuture.wait()

    print("web server shut down.")
}


fileprivate let fileExtensionMediaTypeMapping: [String: String] = [
    "ez": "application/andrew-inset",
    "anx": "application/annodex",
    "atom": "application/atom+xml",
    "atomcat": "application/atomcat+xml",
    "atomsrv": "application/atomserv+xml",
    "lin": "application/bbolin",
    "cu": "application/cu-seeme",
    "davmount": "application/davmount+xml",
    "dcm": "application/dicom",
    "tsp": "application/dsptype",
    "es": "application/ecmascript",
    "spl": "application/futuresplash",
    "hta": "application/hta",
    "jar": "application/java-archive",
    "ser": "application/java-serialized-object",
    "class": "application/java-vm",
    "js": "application/javascript",
    "json": "application/json",
    "m3g": "application/m3g",
    "hqx": "application/mac-binhex40",
    "cpt": "application/mac-compactpro",
    "nb": "application/mathematica",
    "nbp": "application/mathematica",
    "mbox": "application/mbox",
    "mdb": "application/msaccess",
    "doc": "application/msword",
    "dot": "application/msword",
    "mxf": "application/mxf",
    "bin": "application/octet-stream",
    "oda": "application/oda",
    "ogx": "application/ogg",
    "one": "application/onenote",
    "onetoc2": "application/onenote",
    "onetmp": "application/onenote",
    "onepkg": "application/onenote",
    "pdf": "application/pdf",
    "pgp": "application/pgp-encrypted",
    "key": "application/pgp-keys",
    "sig": "application/pgp-signature",
    "prf": "application/pics-rules",
    "ps": "application/postscript",
    "ai": "application/postscript",
    "eps": "application/postscript",
    "epsi": "application/postscript",
    "epsf": "application/postscript",
    "eps2": "application/postscript",
    "eps3": "application/postscript",
    "rar": "application/rar",
    "rdf": "application/rdf+xml",
    "rtf": "application/rtf",
    "stl": "application/sla",
    "smi": "application/smil+xml",
    "smil": "application/smil+xml",
    "xhtml": "application/xhtml+xml",
    "xht": "application/xhtml+xml",
    "xml": "application/xml",
    "xsd": "application/xml",
    "xsl": "application/xslt+xml",
    "xslt": "application/xslt+xml",
    "xspf": "application/xspf+xml",
    "zip": "application/zip",
    "apk": "application/vnd.android.package-archive",
    "cdy": "application/vnd.cinderella",
    "kml": "application/vnd.google-earth.kml+xml",
    "kmz": "application/vnd.google-earth.kmz",
    "xul": "application/vnd.mozilla.xul+xml",
    "xls": "application/vnd.ms-excel",
    "xlb": "application/vnd.ms-excel",
    "xlt": "application/vnd.ms-excel",
    "xlam": "application/vnd.ms-excel.addin.macroEnabled.12",
    "xlsb": "application/vnd.ms-excel.sheet.binary.macroEnabled.12",
    "xlsm": "application/vnd.ms-excel.sheet.macroEnabled.12",
    "xltm": "application/vnd.ms-excel.template.macroEnabled.12",
    "eot": "application/vnd.ms-fontobject",
    "thmx": "application/vnd.ms-officetheme",
    "cat": "application/vnd.ms-pki.seccat",
    "ppt": "application/vnd.ms-powerpoint",
    "pps": "application/vnd.ms-powerpoint",
    "ppam": "application/vnd.ms-powerpoint.addin.macroEnabled.12",
    "pptm": "application/vnd.ms-powerpoint.presentation.macroEnabled.12",
    "sldm": "application/vnd.ms-powerpoint.slide.macroEnabled.12",
    "ppsm": "application/vnd.ms-powerpoint.slideshow.macroEnabled.12",
    "potm": "application/vnd.ms-powerpoint.template.macroEnabled.12",
    "docm": "application/vnd.ms-word.document.macroEnabled.12",
    "dotm": "application/vnd.ms-word.template.macroEnabled.12",
    "odc": "application/vnd.oasis.opendocument.chart",
    "odb": "application/vnd.oasis.opendocument.database",
    "odf": "application/vnd.oasis.opendocument.formula",
    "odg": "application/vnd.oasis.opendocument.graphics",
    "otg": "application/vnd.oasis.opendocument.graphics-template",
    "odi": "application/vnd.oasis.opendocument.image",
    "odp": "application/vnd.oasis.opendocument.presentation",
    "otp": "application/vnd.oasis.opendocument.presentation-template",
    "ods": "application/vnd.oasis.opendocument.spreadsheet",
    "ots": "application/vnd.oasis.opendocument.spreadsheet-template",
    "odt": "application/vnd.oasis.opendocument.text",
    "odm": "application/vnd.oasis.opendocument.text-master",
    "ott": "application/vnd.oasis.opendocument.text-template",
    "oth": "application/vnd.oasis.opendocument.text-web",
    "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "sldx": "application/vnd.openxmlformats-officedocument.presentationml.slide",
    "ppsx": "application/vnd.openxmlformats-officedocument.presentationml.slideshow",
    "potx": "application/vnd.openxmlformats-officedocument.presentationml.template",
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "xltx": "application/vnd.openxmlformats-officedocument.spreadsheetml.template",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "dotx": "application/vnd.openxmlformats-officedocument.wordprocessingml.template",
    "cod": "application/vnd.rim.cod",
    "mmf": "application/vnd.smaf",
    "sdc": "application/vnd.stardivision.calc",
    "sds": "application/vnd.stardivision.chart",
    "sda": "application/vnd.stardivision.draw",
    "sdd": "application/vnd.stardivision.impress",
    "sdf": "application/vnd.stardivision.math",
    "sdw": "application/vnd.stardivision.writer",
    "sgl": "application/vnd.stardivision.writer-global",
    "sxc": "application/vnd.sun.xml.calc",
    "stc": "application/vnd.sun.xml.calc.template",
    "sxd": "application/vnd.sun.xml.draw",
    "std": "application/vnd.sun.xml.draw.template",
    "sxi": "application/vnd.sun.xml.impress",
    "sti": "application/vnd.sun.xml.impress.template",
    "sxm": "application/vnd.sun.xml.math",
    "sxw": "application/vnd.sun.xml.writer",
    "sxg": "application/vnd.sun.xml.writer.global",
    "stw": "application/vnd.sun.xml.writer.template",
    "sis": "application/vnd.symbian.install",
    "cap": "application/vnd.tcpdump.pcap",
    "pcap": "application/vnd.tcpdump.pcap",
    "vsd": "application/vnd.visio",
    "wbxml": "application/vnd.wap.wbxml",
    "wmlc": "application/vnd.wap.wmlc",
    "wmlsc": "application/vnd.wap.wmlscriptc",
    "wpd": "application/vnd.wordperfect",
    "wp5": "application/vnd.wordperfect5.1",
    "wk": "application/x-123",
    "7z": "application/x-7z-compressed",
    "abw": "application/x-abiword",
    "dmg": "application/x-apple-diskimage",
    "bcpio": "application/x-bcpio",
    "torrent": "application/x-bittorrent",
    "cab": "application/x-cab",
    "cbr": "application/x-cbr",
    "cbz": "application/x-cbz",
    "cdf": "application/x-cdf",
    "cda": "application/x-cdf",
    "vcd": "application/x-cdlink",
    "pgn": "application/x-chess-pgn",
    "mph": "application/x-comsol",
    "cpio": "application/x-cpio",
    "csh": "application/x-csh",
    "deb": "application/x-debian-package",
    "udeb": "application/x-debian-package",
    "dcr": "application/x-director",
    "dir": "application/x-director",
    "dxr": "application/x-director",
    "dms": "application/x-dms",
    "wad": "application/x-doom",
    "dvi": "application/x-dvi",
    "pfa": "application/x-font",
    "pfb": "application/x-font",
    "gsf": "application/x-font",
    "pcf": "application/x-font",
    "pcf.Z": "application/x-font",
    "woff": "application/x-font-woff",
    "mm": "application/x-freemind",
    "gan": "application/x-ganttproject",
    "gnumeric": "application/x-gnumeric",
    "sgf": "application/x-go-sgf",
    "gcf": "application/x-graphing-calculator",
    "gtar": "application/x-gtar",
    "tgz": "application/x-gtar-compressed",
    "taz": "application/x-gtar-compressed",
    "hdf": "application/x-hdf",
    "hwp": "application/x-hwp",
    "ica": "application/x-ica",
    "info": "application/x-info",
    "ins": "application/x-internet-signup",
    "isp": "application/x-internet-signup",
    "iii": "application/x-iphone",
    "iso": "application/x-iso9660-image",
    "jam": "application/x-jam",
    "jnlp": "application/x-java-jnlp-file",
    "jmz": "application/x-jmol",
    "chrt": "application/x-kchart",
    "kil": "application/x-killustrator",
    "skp": "application/x-koan",
    "skd": "application/x-koan",
    "skt": "application/x-koan",
    "skm": "application/x-koan",
    "kpr": "application/x-kpresenter",
    "kpt": "application/x-kpresenter",
    "ksp": "application/x-kspread",
    "kwd": "application/x-kword",
    "kwt": "application/x-kword",
    "latex": "application/x-latex",
    "lha": "application/x-lha",
    "lyx": "application/x-lyx",
    "lzh": "application/x-lzh",
    "lzx": "application/x-lzx",
    "frm": "application/x-maker",
    "maker": "application/x-maker",
    "frame": "application/x-maker",
    "fm": "application/x-maker",
    "fb": "application/x-maker",
    "book": "application/x-maker",
    "fbdoc": "application/x-maker",
    "md5": "application/x-md5",
    "mif": "application/x-mif",
    "m3u8": "application/x-mpegURL",
    "wmd": "application/x-ms-wmd",
    "wmz": "application/x-ms-wmz",
    "com": "application/x-msdos-program",
    "exe": "application/x-msdos-program",
    "bat": "application/x-msdos-program",
    "dll": "application/x-msdos-program",
    "msi": "application/x-msi",
    "nc": "application/x-netcdf",
    "pac": "application/x-ns-proxy-autoconfig",
    "dat": "application/x-ns-proxy-autoconfig",
    "nwc": "application/x-nwc",
    "o": "application/x-object",
    "oza": "application/x-oz-application",
    "p7r": "application/x-pkcs7-certreqresp",
    "crl": "application/x-pkcs7-crl",
    "pyc": "application/x-python-code",
    "pyo": "application/x-python-code",
    "qgs": "application/x-qgis",
    "shp": "application/x-qgis",
    "shx": "application/x-qgis",
    "qtl": "application/x-quicktimeplayer",
    "rdp": "application/x-rdp",
    "rpm": "application/x-redhat-package-manager",
    "rss": "application/x-rss+xml",
    "rb": "application/x-ruby",
    "sci": "application/x-scilab",
    "sce": "application/x-scilab",
    "xcos": "application/x-scilab-xcos",
    "sh": "application/x-sh",
    "sha1": "application/x-sha1",
    "shar": "application/x-shar",
    "swf": "application/x-shockwave-flash",
    "swfl": "application/x-shockwave-flash",
    "scr": "application/x-silverlight",
    "sql": "application/x-sql",
    "sit": "application/x-stuffit",
    "sitx": "application/x-stuffit",
    "sv4cpio": "application/x-sv4cpio",
    "sv4crc": "application/x-sv4crc",
    "tar": "application/x-tar",
    "tcl": "application/x-tcl",
    "gf": "application/x-tex-gf",
    "pk": "application/x-tex-pk",
    "texinfo": "application/x-texinfo",
    "texi": "application/x-texinfo",
    "~": "application/x-trash",
    "%": "application/x-trash",
    "bak": "application/x-trash",
    "old": "application/x-trash",
    "sik": "application/x-trash",
    "t": "application/x-troff",
    "tr": "application/x-troff",
    "roff": "application/x-troff",
    "man": "application/x-troff-man",
    "me": "application/x-troff-me",
    "ms": "application/x-troff-ms",
    "ustar": "application/x-ustar",
    "src": "application/x-wais-source",
    "wz": "application/x-wingz",
    "crt": "application/x-x509-ca-cert",
    "xcf": "application/x-xcf",
    "fig": "application/x-xfig",
    "xpi": "application/x-xpinstall",
    "amr": "audio/amr",
    "awb": "audio/amr-wb",
    "axa": "audio/annodex",
    "au": "audio/basic",
    "snd": "audio/basic",
    "csd": "audio/csound",
    "orc": "audio/csound",
    "sco": "audio/csound",
    "flac": "audio/flac",
    "mid": "audio/midi",
    "midi": "audio/midi",
    "kar": "audio/midi",
    "mpga": "audio/mpeg",
    "mpega": "audio/mpeg",
    "mp2": "audio/mpeg",
    "mp3": "audio/mpeg",
    "m4a": "audio/mpeg",
    "m3u": "audio/mpegurl",
    "oga": "audio/ogg",
    "ogg": "audio/ogg",
    "opus": "audio/ogg",
    "spx": "audio/ogg",
    "sid": "audio/prs.sid",
    "aif": "audio/x-aiff",
    "aiff": "audio/x-aiff",
    "aifc": "audio/x-aiff",
    "gsm": "audio/x-gsm",
    "wma": "audio/x-ms-wma",
    "wax": "audio/x-ms-wax",
    "ra": "audio/x-pn-realaudio",
    "rm": "audio/x-pn-realaudio",
    "ram": "audio/x-pn-realaudio",
    "pls": "audio/x-scpls",
    "sd2": "audio/x-sd2",
    "wav": "audio/x-wav",
    "alc": "chemical/x-alchemy",
    "cac": "chemical/x-cache",
    "cache": "chemical/x-cache",
    "csf": "chemical/x-cache-csf",
    "cbin": "chemical/x-cactvs-binary",
    "cascii": "chemical/x-cactvs-binary",
    "ctab": "chemical/x-cactvs-binary",
    "cdx": "chemical/x-cdx",
    "cer": "chemical/x-cerius",
    "c3d": "chemical/x-chem3d",
    "chm": "chemical/x-chemdraw",
    "cif": "chemical/x-cif",
    "cmdf": "chemical/x-cmdf",
    "cml": "chemical/x-cml",
    "cpa": "chemical/x-compass",
    "bsd": "chemical/x-crossfire",
    "csml": "chemical/x-csml",
    "csm": "chemical/x-csml",
    "ctx": "chemical/x-ctx",
    "cxf": "chemical/x-cxf",
    "cef": "chemical/x-cxf",
    "emb": "chemical/x-embl-dl-nucleotide",
    "embl": "chemical/x-embl-dl-nucleotide",
    "spc": "chemical/x-galactic-spc",
    "inp": "chemical/x-gamess-input",
    "gam": "chemical/x-gamess-input",
    "gamin": "chemical/x-gamess-input",
    "fch": "chemical/x-gaussian-checkpoint",
    "fchk": "chemical/x-gaussian-checkpoint",
    "cub": "chemical/x-gaussian-cube",
    "gau": "chemical/x-gaussian-input",
    "gjc": "chemical/x-gaussian-input",
    "gjf": "chemical/x-gaussian-input",
    "gal": "chemical/x-gaussian-log",
    "gcg": "chemical/x-gcg8-sequence",
    "gen": "chemical/x-genbank",
    "hin": "chemical/x-hin",
    "istr": "chemical/x-isostar",
    "ist": "chemical/x-isostar",
    "jdx": "chemical/x-jcamp-dx",
    "dx": "chemical/x-jcamp-dx",
    "kin": "chemical/x-kinemage",
    "mcm": "chemical/x-macmolecule",
    "mmd": "chemical/x-macromodel-input",
    "mmod": "chemical/x-macromodel-input",
    "mol": "chemical/x-mdl-molfile",
    "rd": "chemical/x-mdl-rdfile",
    "rxn": "chemical/x-mdl-rxnfile",
    "sd": "chemical/x-mdl-sdfile",
    "tgf": "chemical/x-mdl-tgf",
    "mcif": "chemical/x-mmcif",
    "mol2": "chemical/x-mol2",
    "b": "chemical/x-molconn-Z",
    "gpt": "chemical/x-mopac-graph",
    "mop": "chemical/x-mopac-input",
    "mopcrt": "chemical/x-mopac-input",
    "mpc": "chemical/x-mopac-input",
    "zmt": "chemical/x-mopac-input",
    "moo": "chemical/x-mopac-out",
    "mvb": "chemical/x-mopac-vib",
    "asn": "chemical/x-ncbi-asn1",
    "prt": "chemical/x-ncbi-asn1-ascii",
    "ent": "chemical/x-ncbi-asn1-ascii",
    "val": "chemical/x-ncbi-asn1-binary",
    "aso": "chemical/x-ncbi-asn1-binary",
    "pdb": "chemical/x-pdb",
    "ros": "chemical/x-rosdal",
    "sw": "chemical/x-swissprot",
    "vms": "chemical/x-vamas-iso14976",
    "vmd": "chemical/x-vmd",
    "xtel": "chemical/x-xtel",
    "xyz": "chemical/x-xyz",
    "gif": "image/gif",
    "ief": "image/ief",
    "jp2": "image/jp2",
    "jpg2": "image/jp2",
    "jpeg": "image/jpeg",
    "jpg": "image/jpeg",
    "jpe": "image/jpeg",
    "jpm": "image/jpm",
    "jpx": "image/jpx",
    "jpf": "image/jpx",
    "pcx": "image/pcx",
    "png": "image/png",
    "svg": "image/svg+xml",
    "svgz": "image/svg+xml",
    "tiff": "image/tiff",
    "tif": "image/tiff",
    "djvu": "image/vnd.djvu",
    "djv": "image/vnd.djvu",
    "ico": "image/vnd.microsoft.icon",
    "wbmp": "image/vnd.wap.wbmp",
    "cr2": "image/x-canon-cr2",
    "crw": "image/x-canon-crw",
    "ras": "image/x-cmu-raster",
    "cdr": "image/x-coreldraw",
    "pat": "image/x-coreldrawpattern",
    "cdt": "image/x-coreldrawtemplate",
    "erf": "image/x-epson-erf",
    "art": "image/x-jg",
    "jng": "image/x-jng",
    "bmp": "image/x-ms-bmp",
    "nef": "image/x-nikon-nef",
    "orf": "image/x-olympus-orf",
    "psd": "image/x-photoshop",
    "pnm": "image/x-portable-anymap",
    "pbm": "image/x-portable-bitmap",
    "pgm": "image/x-portable-graymap",
    "ppm": "image/x-portable-pixmap",
    "rgb": "image/x-rgb",
    "xbm": "image/x-xbitmap",
    "xpm": "image/x-xpixmap",
    "xwd": "image/x-xwindowdump",
    "eml": "message/rfc822",
    "igs": "model/iges",
    "iges": "model/iges",
    "msh": "model/mesh",
    "mesh": "model/mesh",
    "silo": "model/mesh",
    "wrl": "model/vrml",
    "vrml": "model/vrml",
    "x3dv": "model/x3d+vrml",
    "x3d": "model/x3d+xml",
    "x3db": "model/x3d+binary",
    "appcache": "text/cache-manifest",
    "ics": "text/calendar",
    "icz": "text/calendar",
    "css": "text/css",
    "csv": "text/csv",
    "323": "text/h323",
    "html": "text/html",
    "htm": "text/html",
    "shtml": "text/html",
    "uls": "text/iuls",
    "mml": "text/mathml",
    "asc": "text/plain",
    "txt": "text/plain",
    "text": "text/plain",
    "pot": "text/plain",
    "brf": "text/plain",
    "srt": "text/plain",
    "rtx": "text/richtext",
    "sct": "text/scriptlet",
    "wsc": "text/scriptlet",
    "tm": "text/texmacs",
    "tsv": "text/tab-separated-values",
    "ttl": "text/turtle",
    "jad": "text/vnd.sun.j2me.app-descriptor",
    "wml": "text/vnd.wap.wml",
    "wmls": "text/vnd.wap.wmlscript",
    "bib": "text/x-bibtex",
    "boo": "text/x-boo",
    "h++": "text/x-c++hdr",
    "hpp": "text/x-c++hdr",
    "hxx": "text/x-c++hdr",
    "hh": "text/x-c++hdr",
    "c++": "text/x-c++src",
    "cpp": "text/x-c++src",
    "cxx": "text/x-c++src",
    "cc": "text/x-c++src",
    "h": "text/x-chdr",
    "htc": "text/x-component",
    "c": "text/x-csrc",
    "d": "text/x-dsrc",
    "diff": "text/x-diff",
    "patch": "text/x-diff",
    "hs": "text/x-haskell",
    "java": "text/x-java",
    "ly": "text/x-lilypond",
    "lhs": "text/x-literate-haskell",
    "moc": "text/x-moc",
    "p": "text/x-pascal",
    "pas": "text/x-pascal",
    "gcd": "text/x-pcs-gcd",
    "pl": "text/x-perl",
    "pm": "text/x-perl",
    "py": "text/x-python",
    "scala": "text/x-scala",
    "etx": "text/x-setext",
    "sfv": "text/x-sfv",
    "tk": "text/x-tcl",
    "tex": "text/x-tex",
    "ltx": "text/x-tex",
    "sty": "text/x-tex",
    "cls": "text/x-tex",
    "vcs": "text/x-vcalendar",
    "vcf": "text/x-vcard",
    "3gp": "video/3gpp",
    "axv": "video/annodex",
    "dl": "video/dl",
    "dif": "video/dv",
    "dv": "video/dv",
    "fli": "video/fli",
    "gl": "video/gl",
    "mpeg": "video/mpeg",
    "mpg": "video/mpeg",
    "mpe": "video/mpeg",
    "ts": "video/MP2T",
    "mp4": "video/mp4",
    "qt": "video/quicktime",
    "mov": "video/quicktime",
    "ogv": "video/ogg",
    "webm": "video/webm",
    "mxu": "video/vnd.mpegurl",
    "flv": "video/x-flv",
    "lsf": "video/x-la-asf",
    "lsx": "video/x-la-asf",
    "mng": "video/x-mng",
    "asf": "video/x-ms-asf",
    "asx": "video/x-ms-asf",
    "wm": "video/x-ms-wm",
    "wmv": "video/x-ms-wmv",
    "wmx": "video/x-ms-wmx",
    "wvx": "video/x-ms-wvx",
    "avi": "video/x-msvideo",
    "movie": "video/x-sgi-movie",
    "mpv": "video/x-matroska",
    "mkv": "video/x-matroska",
    "ice": "x-conference/x-cooltalk",
    "sisx": "x-epoc/x-sisx-app",
    "vrm": "x-world/x-vrml",
]

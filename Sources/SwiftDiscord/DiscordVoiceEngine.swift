// The MIT License (MIT)
// Copyright (c) 2016 Erik Little

// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
// documentation files (the "Software"), to deal in the Software without restriction, including without
// limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the
// Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the
// Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING
// BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
// EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.

public typealias DiscordVoiceData = (rtpHeader: [UInt8], voiceData: [UInt8])

#if !os(iOS)

import Foundation
import Dispatch
#if os(macOS)
import Starscream
#else
import WebSockets
#endif
import Socks
import Sodium

enum DiscordVoiceEngineError : Error {
	case ipExtraction
}

public final class DiscordVoiceEngine : DiscordEngine, DiscordVoiceEngineSpec {
	public override var connectURL: String {
		return "wss://" + endpoint.components(separatedBy: ":")[0]
	}

	public override var engineType: String {
		return "voiceEngine"
	}

	public private(set) var connected = false
	public private(set) var encoder: DiscordVoiceEncoder?
	public private(set) var endpoint: String!
	public private(set) var modes = [String]()
	public private(set) var secret: [UInt8]!
	public private(set) var ssrc: UInt32 = 0
	public private(set) var udpSocket: UDPClient?
	public private(set) var udpPort = -1
	public private(set) var voiceServerInformation: [String: Any]!

	private let udpQueue = DispatchQueue(label: "discordVoiceEngine.udpQueue")
	private let udpQueueRead = DispatchQueue(label: "discordVoiceEngine.udpQueueRead")

	private var currentUnixTime: Int {
		return Int(Date().timeIntervalSince1970 * 1000)
	}

	private var closed = false

    #if os(macOS)
	private var sequenceNum = UInt16(arc4random() >> 16)
	private var timestamp = arc4random()
    #else
    private var sequenceNum = UInt16(random() >> 16)
    private var timestamp = random()
    #endif

	private var startTime = 0

	public convenience init?(client: DiscordClientSpec, voiceServerInformation: [String: Any],
			encoder: DiscordVoiceEncoder?, secret: [UInt8]?) {
		self.init(client: client)

		_ = sodium_init()

		self.voiceServerInformation = voiceServerInformation
		self.encoder = encoder
		self.secret = secret

		if let endpoint = voiceServerInformation["endpoint"] as? String {
			self.endpoint = endpoint
		} else {
			return nil
		}
	}

	deinit {
		disconnect()
	}

	private func audioSleep(_ count: Int) {
		let inner = (startTime + count * 20) - currentUnixTime
		let waitTime = Double(20 + inner) / 1000.0

		guard waitTime > 0 else { return }

		// print("sleeping \(waitTime) \(count)")
		Thread.sleep(forTimeInterval: waitTime)
	}

	private func createEncoder() {
		encoder = nil

		signal(SIGPIPE, SIG_IGN)

		encoder = DiscordVoiceEncoder()

		readData(1)

		client?.handleEvent("voiceEngine.ready", with: [])
	}

	public override func createHandshakeObject() -> [String: Any] {
		// print("DiscordVoiceEngine: Creating handshakeObject")

		return [
			"session_id": client!.voiceState!.sessionId,
			"server_id": client!.voiceState!.guildId,
			"user_id": client!.user!.id,
			"token": voiceServerInformation["token"] as! String
		]
	}

	private func createRTPHeader() -> [UInt8] {
		func resetByteNumber(_ byteNumber: inout Int,  _ i: Int) {
			if i == 1 || i == 5 {
				byteNumber = 0
			} else {
				byteNumber += 1
			}
		}

		var rtpHeader = [UInt8](repeating: 0x00, count: 12)
		var byteNumber = 0
		var currentHeaderIndex = 2

		rtpHeader[0] = 0x80
		rtpHeader[1] = 0x78

		let sequenceBigEndian = sequenceNum.bigEndian
		let ssrcBigEndian = ssrc.bigEndian
		let timestampBigEndian = timestamp.bigEndian

		for i in 0..<10 {
			if i < 2 {
				rtpHeader[currentHeaderIndex] = UInt8((Int(sequenceBigEndian) >> (8 * byteNumber)) & 0xFF)

				resetByteNumber(&byteNumber, i)
			} else if i < 6 {
				rtpHeader[currentHeaderIndex] = UInt8((Int(timestampBigEndian) >> (8 * byteNumber)) & 0xFF)

				resetByteNumber(&byteNumber, i)
			} else {
				rtpHeader[currentHeaderIndex] = UInt8((Int(ssrcBigEndian) >> (8 * byteNumber)) & 0xFF)

				byteNumber += 1
			}

            currentHeaderIndex += 1
		}

		return rtpHeader
	}

	private func decryptVoiceData(_ data: Data) {
		defer { free(unencrypted) }

		let rtpHeader = Array(data.prefix(12))
		let voiceData = Array(data.dropFirst(12))
		let audioSize = voiceData.count - Int(crypto_secretbox_MACBYTES)
		let unencrypted = UnsafeMutablePointer<UInt8>.allocate(capacity: audioSize)
		let padding = [UInt8](repeating: 0x00, count: 12)
		var nonce = rtpHeader + padding

		let success = crypto_secretbox_open_easy(unencrypted, voiceData, UInt64(data.count - 12), &nonce, &self.secret!)

		// Decryption failure
		guard success != -1 else { return }

		self.client?.handleVoiceData(DiscordVoiceData(rtpHeader: rtpHeader,
			voiceData: Array(UnsafeBufferPointer<UInt8>(start: unencrypted, count: audioSize))))
	}

	public override func disconnect() {
		// print("DiscordVoiceEngine: Disconnecting")

		super.disconnect()

		do {
			try udpSocket?.close()
		} catch {}

		connected = false
		encoder = nil
	}

	private func extractIPAndPort(from bytes: [UInt8]) throws -> (String, Int) {
		// print("extracting our ip and port from \(bytes)")

		let ipData = Data(bytes: bytes.dropLast(2))
		let portBytes = Array(bytes.suffix(from: bytes.endIndex.advanced(by: -2)))
		let port = (Int(portBytes[0]) | Int(portBytes[1])) &<< 8

		guard let ipString = String(data: ipData, encoding: .utf8)?.replacingOccurrences(of: "\0", with: "") else {
			throw DiscordVoiceEngineError.ipExtraction
		}

		return (ipString, port)
	}

	// https://discordapp.com/developers/docs/topics/voice-connections#ip-discovery
	private func findIP() {
		udpQueue.async {
			guard let udpSocket = self.udpSocket else { return }

			// print("Finding IP")
			let discoveryData = [UInt8](repeating: 0x00, count: 70)

			do {
				try udpSocket.send(bytes: discoveryData)

				let (data, _) = try udpSocket.receive(maxBytes: 70)
				let (ip, port) = try self.extractIPAndPort(from: data)

				self.selectProtocol(with: ip, on: port)
			} catch {
				// print("Something blew up")
				self.disconnect()
			}
		}
	}

	override func _handleGatewayPayload(_ payload: DiscordGatewayPayload) {
		guard case let .voice(voiceCode) = payload.code else {
			fatalError("Got gateway payload in non gateway engine")
		}

		switch voiceCode {
		case .ready:
			handleReady(with: payload.payload)
		case .sessionDescription:
			udpQueue.async { self.handleVoiceSessionDescription(with: payload.payload) }
		default:
			// print("Got voice payload \(payload)")
			break
		}
	}

	private func handleReady(with payload: DiscordGatewayPayloadData) {
		guard case let .object(voiceInformation) = payload,
			let heartbeatInterval = voiceInformation["heartbeat_interval"] as? Int,
			let ssrc = voiceInformation["ssrc"] as? Int, let udpPort = voiceInformation["port"] as? Int,
			let modes = voiceInformation["modes"] as? [String] else {
				// TODO tell them the voice connection failed
				disconnect()

				return
			}

		self.udpPort = udpPort
		self.modes = modes
		self.ssrc = UInt32(ssrc)
		self.heartbeatInterval = heartbeatInterval

		startUDP()
	}

	private func handleVoiceSessionDescription(with payload: DiscordGatewayPayloadData) {
		guard case let .object(voiceInformation) = payload,
			let secret = voiceInformation["secret_key"] as? [Int] else {
				// TODO tell them we failed
				disconnect()

				return
			}

		self.secret = secret.map({ UInt8($0) })
	}

	public override func parseGatewayMessage(_ string: String) {
		guard let decoded = DiscordGatewayPayload.payloadFromString(string, fromGateway: false) else {
			print("DiscordVoiceEngine: Got unknown payload \(string), Endpoint is: \(endpoint!)")

			return
		}

		handleGatewayPayload(decoded)
	}

	private func readData(_ count: Int) {
		encoder?.read {[weak self] done, data in
			guard let this = self, this.connected else { return } // engine died

		    guard !done else {
		    	// print("no data, reader probably closed")

		    	this.sendGatewayPayload(DiscordGatewayPayload(code: .voice(.speaking), payload: .object([
		    		"speaking": false,
		    		"delay": 0
		    	])))

		    	DispatchQueue.main.async {
		    		this.createEncoder()
		    	}

		    	return
		    }

		    // print("Read \(data)")

		    if count == 1 {
		    	this.startTime = this.currentUnixTime

		    	this.sendGatewayPayload(DiscordGatewayPayload(code: .voice(.speaking), payload: .object([
		    		"speaking": true,
		    		"delay": 0
		    	])))
		    }

		    this.sendVoiceData(data)

		    this.sequenceNum = this.sequenceNum &+ 1
		    this.timestamp = this.timestamp &+ 960

		    this.audioSleep(count)
		    this.readData(count + 1)
		}
	}

	private func readSocket() {
		udpQueueRead.async {[weak self] in
			guard let socket = self?.udpSocket else { return }

			do {
				let (data, _) = try socket.receive(maxBytes: 4096)

				self?.decryptVoiceData(Data(bytes: data))
			} catch {
				// print("Error reading socket data")
			}

			self?.readSocket()
		}
	}

	// Tells the voice websocket what our ip and port is, and what encryption mode we will use
	// currently only xsalsa20_poly1305 is supported
	// After this point we are good to go in sending encrypted voice packets
	private func selectProtocol(with ip: String, on port: Int) {
		// print("Selecting UDP protocol with ip: \(ip) on port: \(port)")

		let payloadData: [String: Any] = [
			"protocol": "udp",
			"data": [
				"address": ip,
				"port": port,
				"mode": "xsalsa20_poly1305"
			]
		]

		sendGatewayPayload(DiscordGatewayPayload(code: .voice(.selectProtocol), payload: .object(payloadData)))
		startHeartbeat(seconds: heartbeatInterval / 1000)
		connected = true

		if encoder == nil {
			// We are the first engine the client had, or they didn't give us an encoder to use
			createEncoder()
		} else {
			// We inherited a previous engine's encoder, read from it
			readData(1)
		}

		readSocket()
	}

	public override func sendHeartbeat() {
		guard !closed else { return }

		sendGatewayPayload(DiscordGatewayPayload(code: .voice(.heartbeat), payload: .integer(currentUnixTime)))

		let time = DispatchTime.now() + Double(heartbeatInterval)

		heartbeatQueue.asyncAfter(deadline: time) {[weak self] in self?.sendHeartbeat() }
	}

	public func sendVoiceData(_ data: [UInt8]) {
		udpQueue.sync {
			guard let udpSocket = self.udpSocket, data.count <= defaultAudioSize else { return }
			defer { free(encrypted) }

			// print("Should send voice data: \(data.count) bytes")

            var buf = data

            let audioSize = Int(crypto_secretbox_MACBYTES) + defaultAudioSize
            let encrypted = UnsafeMutablePointer<UInt8>.allocate(capacity: audioSize)
            let padding = [UInt8](repeating: 0x00, count: 12)

            let rtpHeader = self.createRTPHeader()
            let enryptedCount = Int(crypto_secretbox_MACBYTES) + data.count
            var nonce = rtpHeader + padding

            _ = crypto_secretbox_easy(encrypted, &buf, UInt64(buf.count), &nonce, &self.secret!)

            let encryptedBytes = Array(UnsafeBufferPointer<UInt8>(start: encrypted, count: enryptedCount))
            try? udpSocket.send(bytes: rtpHeader + encryptedBytes)
		}
	}

	public func requestFileHandleForWriting() -> FileHandle? {
		return self.encoder?.readPipe.fileHandleForWriting
	}

	public func requestNewEncoder() {
		encoder?.closeEncoder()
	}

	public override func startHandshake() {
		guard client != nil else { return }

		// print("DiscordVoiceEngine: Starting voice handshake")

		let handshakeEventData = createHandshakeObject()

		sendGatewayPayload(DiscordGatewayPayload(code: .voice(.identify), payload: .object(handshakeEventData)))
	}

	private func startUDP() {
		guard udpPort != -1 else { return }

		let base = endpoint.components(separatedBy: ":")[0]
		let udpEndpoint = InternetAddress(hostname: base, port: UInt16(udpPort))

		guard let client = try? UDPClient(address: udpEndpoint) else {
			self.disconnect()

			return
		}

		udpSocket = client

		// Begin async UDP setup
		findIP()
	}
}

#endif

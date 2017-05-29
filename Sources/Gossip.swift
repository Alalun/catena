import Foundation
import Kitura
import KituraRequest
import LoggerAPI

extension Block {
	var json: [String: Any] {
		return [
			"hash": self.signature!.stringValue,
			"index": self.index,
			"nonce": self.nonce,
			"payload": self.payloadData.base64EncodedString(),
			"previous": self.previous.stringValue
		]
	}

	static func read(json: [String: Any]) throws -> Self {
		if let nonce = json["nonce"] as? Int,
			let signature = json["hash"] as? String,
			let height = json["index"] as? Int,
			let previous = json["previous"] as? String,
			let payloadBase64 = json["payload"] as? String,
			let payload = Data(base64Encoded: payloadBase64),
			let previousHash = Hash(string: previous),
			let signatureHash = Hash(string: signature) {
				var b = try Self.init(index: UInt(height), previous: previousHash, payload: payload)
				b.nonce = UInt(nonce)
				b.signature = signatureHash
				return b
			}
			else {
				throw BlockError.formatError
			}
	}
}

class Server<BlockType: Block> {
	private let version = 1
	let router = Router()
	let port: Int
	weak var node: Node<BlockType>?

	init(node: Node<BlockType>, port: Int) {
		self.node = node
		self.port = port

		// Part of API used between nodes
		router.post("/", handler: self.handleIndex)
		router.get("/", handler: self.handleIndex)
		router.post("/block", handler: self.handlePostBlock)
		router.get("/block/:hash", handler: self.handleGetBlock)

		// Not part of the API used between nodes
		router.get("/info/orphans", handler: self.handleGetOrphans)
		router.get("/info/head", handler: self.handleGetLast)

		Kitura.addHTTPServer(onPort: port, with: router)
	}

	/** Other peers will GET this, or POST with a JSON object containing their own UUID (string) and port (number). */
	private func handleIndex(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
		if request.method == .post {
			var data = Data(capacity: 4096)
			do {
				if try request.read(into: &data) > 0 {
					if	let params = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
						let _ = params["uuid"] as? String,
						let port = params["port"] as? Int {

						// Tell node that we have made contact with a new peer
						var uc = URLComponents()
						uc.scheme = "http"
						uc.host = request.remoteAddress
						uc.port = port
						if let u = uc.url {
							self.node?.add(peer: Peer(URL: u))
						}
					}
					else {
						_ = response.send(status: .badRequest)
						return
					}
				}
				else {
					_ = response.send(status: .badRequest)
					return
				}
			}
			catch {
				_ = response.send(status: .badRequest)
				return
			}
		}

		response.send(json: [
			"version": self.version,
			"uuid": self.node!.uuid.uuidString,

			"longest": self.node!.ledger.mutex.locked { return [
				"highest": self.node!.ledger.longest.highest.json,
				"genesis": self.node!.ledger.longest.genesis.json
			]},

			"peers": Array(self.node!.validPeers.flatMap { return $0.url.absoluteString })
		])
		next()
	}

	private func handlePostBlock(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
		assert(request.method == .post, "Must be post")

		var data = Data(capacity: 4096)
		do {
			if try request.read(into: &data) > 0 {
				if let params = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
					let block = try BlockType.read(json: params)
					self.node?.ledger.mutex.locked {
						Log.info("[Server] received post: \(block)")
						_ = self.node?.ledger.receive(block: block)
					}

					response.send(json: [
						"version": self.version
					])
				}
				else {
					_ = response.send(status: .badRequest)
					return
				}
			}
			else {
				_ = response.send(status: .badRequest)
				return
			}
		}
		catch {
			_ = response.send(status: .badRequest)
			return
		}

		next()
	}

	private func handleGetBlock(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
		if let hashString = request.parameters["hash"], let hash = Hash(string: hashString) {
			if let ledger = self.node?.ledger {
				let block = ledger.mutex.locked {
					return ledger.longest.blocks[hash]
				}

				if let b = block {
					response.send(json: b.json)

					next()
				}
				else {
					_ = response.send(status: .notFound)
				}
			}
			else {
				_ = response.send(status: .internalServerError)
			}
		}
		else {
			_ = response.send(status: .badRequest)
		}
	}

	private func handleGetOrphans(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
		let hashes = Array(self.node!.ledger.orphansByHash.keys.map { $0.stringValue })
		response.send(json: [
			"status": "ok",
			"orphans": hashes
		])
		next()
	}

	private func handleGetLast(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
		let chain = self.node!.ledger.longest
		var b: BlockType? = chain.highest
		var data: [[String: Any]] = []
		for _ in 0..<10 {
			if let block = b {
				data.append([
					"index": block.index,
					"hash": block.signature!.stringValue
				])
				b = chain.blocks[block.previous]
			}
			else {
				break
			}
		}

		response.send(json: [
			"status": "ok",
			"blocks": data
		])
		next()
	}
}

public class Peer<BlockType: Block>: Hashable, CustomDebugStringConvertible {
	struct Index {
		let version: Int
		let uuid: UUID
		let genesis: Hash
		let peers: [String]
		let highest: Hash
		let height: UInt
	}

	let url: URL

	public static func ==(lhs: Peer<BlockType>, rhs: Peer<BlockType>) -> Bool {
		return lhs.url == rhs.url
	}

	public var debugDescription: String {
		return "Peer \(self.url.absoluteString)"
	}

	public init(URL: URL) {
		self.url = URL
	}

	public var hashValue: Int {
		return url.hashValue
	}

	private func call(path: String, parameters: [String: Any]? = nil, callback: @escaping (Fallible<[String: Any]>) -> ()) {
		let u = self.url.appendingPathComponent(path).absoluteString
		let request = KituraRequest.request(parameters != nil ? .post : .get, u, parameters: parameters, encoding: JSONEncoding(options: []))

		request.response { request, response, data, error in
			if let e = error {
				return callback(.failure(e.localizedDescription))
			}

			if let r = response, r.statusCode == .OK {
				if let d = data {
					do {
						let answer = try JSONSerialization.jsonObject(with: d, options: [])
						if let answer = answer as? [String: Any] {
							return callback(.success(answer))
						}
						else {
							return callback(.failure("invalid JSON structure"))
						}
					}
					catch {
						return callback(.failure(error.localizedDescription))
					}
				}
				else {
					return callback(.success([:]))
				}
			}
			else {
				return callback(.failure("HTTP status code \(response?.httpStatusCode.rawValue ?? 0)"))
			}
		}
	}

	func fetch(hash: Hash, callback: @escaping (Fallible<BlockType>) -> ()) {
		self.call(path: "/block/\(hash.stringValue)") { result in
			switch result {
			case .success(let data):
				do {
					let block = try BlockType.read(json: data)
					return callback(.success(block))
				}
				catch {
					return callback(.failure(error.localizedDescription))
				}

			case .failure(let e):
				callback(.failure(e))
			}
		}
	}

	func post(block: BlockType) {
		self.call(path: "/block", parameters: block.json) { result in
			switch result {
			case .success(_):
				break

			case .failure(let e):
				Log.warning("[Peer] Post block failed to peer \(self): \(e)")
			}
		}
	}

	func ping(from: Node<BlockType>? = nil, callback: @escaping (Fallible<Index>) -> ()) {
		var p: [String: Any]? = nil
		if let f = from {
			p = [
				"uuid": f.uuid.uuidString,
				"port": f.server.port
			]
		}

		self.call(path: "/", parameters: p) { result in
			switch result {
			case .success(let answer):
				if let version = answer["version"] as? Int,
					let uuidString = answer["uuid"] as? String, let uuid = UUID(uuidString: uuidString),
					let longest = answer["longest"] as? [String: Any?],
					let genesis = longest["genesis"] as? [String: Any?],
					let highest = longest["highest"] as? [String: Any?],
					let height = highest["index"] as? UInt,
					let genesisHashString = genesis["hash"] as? String,
					let genesisHash = Hash(string: genesisHashString),
					let highestHashString = highest["hash"] as? String,
					let highestHash = Hash(string: highestHashString),
					let peers = answer["peers"] as? [String] {
					let index = Index(version: version, uuid: uuid, genesis: genesisHash, peers: peers, highest: highestHash, height: height)
						return callback(.success(index))
				}
				else {
					return callback(.failure("invalid answer"))
				}

			case .failure(let e):
				return callback(.failure(e))
			}
		}
	}
}

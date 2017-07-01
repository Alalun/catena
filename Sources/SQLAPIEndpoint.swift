import Foundation
import Kitura

class SQLAPIEndpoint {
	let node: Node<SQLBlockchain>

	init(node: Node<SQLBlockchain>, router: Router) {
		self.node = node

		router.get("/api/block/:hash", handler: self.handleGetBlock)
		router.get("/api/orphans", handler: self.handleGetOrphans)
		router.get("/api/head", handler: self.handleGetLast)
		router.get("/api/journal", handler: self.handleGetJournal)
	}

	private func handleGetBlock(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
		if let hashString = request.parameters["hash"], let hash = Hash(string: hashString) {
			let block = try self.node.ledger.mutex.locked {
				return try self.node.ledger.longest.get(block: hash)
			}

			if let b = block {
				assert(b.isSignatureValid, "returning invalid blocks, that can't be good")
				response.send(json: b.json)

				next()
			}
			else {
				_ = response.send(status: .notFound)
			}
		}
		else {
			_ = response.send(status: .badRequest)
		}
	}

	private func handleGetOrphans(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
		let hashes = Array(self.node.ledger.orphansByHash.keys.map { $0.stringValue })
		response.send(json: [
			"status": "ok",
			"orphans": hashes
			])
		next()
	}

	private func handleGetLast(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
		let chain = self.node.ledger.longest
		var b: SQLBlock? = chain.highest
		var data: [[String: Any]] = []
		for _ in 0..<10 {
			if let block = b {
				data.append([
					"index": block.index,
					"hash": block.signature!.stringValue
					])
				b = try chain.get(block: block.previous)
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

	private func handleGetJournal(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
		let chain = self.node.ledger.longest
		var b: SQLBlock? = chain.highest
		var data: [String] = [];
		while let block = b {
			for tr in block.payload.transactions {
				data.append(tr.statement.sql(dialect: SQLStandardDialect()))
			}
			b = try chain.get(block: block.previous)
		}

		response.headers.setType("text/plain", charset: "utf8")
		response.send(data.joined(separator: "\r\n"))
		next()
	}
}

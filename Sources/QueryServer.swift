import Foundation
import LoggerAPI

struct QueryError: LocalizedError {
	let message: String

	init(message: String) {
		self.message = message
	}

	var errorDescription: String? {
		return self.message
	}
}

class NodeQueryServer: QueryServer {
	var node: Node<SQLBlock>

	init(node: Node<SQLBlock>, port: Int, family: Family = .ipv6) {
		self.node = node
		super.init(port: port, family: family)
	}

	override func query(_ query: String, connection: QueryClientConnection) {
		let ledger = node.ledger as! SQLLedger

		Log.info("[Query] Execute: \(query)")

		do {
			// Parse the statement
			let statement = try SQLStatement(query)

			if statement.isMutating {
				// Get user public/private key
				guard let username = connection.username else {
					throw QueryError(message: "no username set")
				}

				guard let password = connection.password else {
					throw QueryError(message: "no password set")
				}

				let identity: Identity

				// for testing, autogenerate a keypair when the username is 'random'
				if username == "random" {
					identity = try Identity()
					try connection.send(error: "Public key: \(identity.publicKey.stringValue)", severity: .info, code: "", endsQuery: false)
					try connection.send(error: "Private key: \(identity.privateKey.stringValue)", severity: .info, code: "", endsQuery: false)
				}
				else {
					guard let invokerKey = PublicKey(string: username) else {
						throw QueryError(message: "no usename set or not a public key")
					}

					guard let passwordKey = PrivateKey(string: password) else {
						throw QueryError(message: "password is not a valid private key")
					}

					identity = Identity(publicKey: invokerKey, privateKey: passwordKey)
				}

				// This needs to go to the ledger
				let transaction = try SQLTransaction(statement: statement, invoker: identity.publicKey)
				try transaction.sign(with: identity.privateKey)
				self.node.submit(transaction: transaction)
				try connection.send(error: "OK \(transaction.signature!.base58encoded) \(transaction.statement.sql(dialect: SQLStandardDialect()))", severity: .info)
			}
			else {
				let result = try ledger.permanentHistory.database.perform(statement.backendSQL(dialect: ledger.permanentHistory.database.dialect))

				if case .row = result.state {
					// Send columns
					let fields = result.columns.map { col in
						return PQField(name: col, tableId: 0, columnId: 0, type: .text, typeModifier: 0)
					}
					try connection.send(description: fields)

					while case .row = result.state {
						let values = result.values.map { val in
							return PQValue.text(val)
						}
						try connection.send(row: values)
						result.step()
					}
				}
				try connection.sendQueryComplete(tag: "SELECT")
			}
		}
		catch {
			// TODO get some more information from the parser
			try? connection.send(error: error.localizedDescription)
		}
	}
}

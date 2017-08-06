import Foundation
import LoggerAPI
import CatenaCore

struct QueryError: LocalizedError {
	let message: String

	init(message: String) {
		self.message = message
	}

	var errorDescription: String? {
		return self.message
	}
}

extension Value {
	var pqValue: PQValue {
		switch self {
		case .text(let s): return PQValue.text(s)
		case .int(let i): return PQValue.int(Int32(i))
		case .float(let d): return PQValue.float8(d)
		case .bool(let b): return PQValue.bool(b)
		case .blob(let b): return PQValue.text(b.base64EncodedString())
		case .null: return PQValue.null
		}
	}
}

public class NodeQueryServer: QueryServer {
	var node: Node<SQLLedger>

	public init(node: Node<SQLLedger>, port: Int, family: Family = .ipv6) {
		self.node = node
		super.init(port: port, family: family)
	}

	public override func query(_ query: String, connection: QueryClientConnection) {
		Log.info("[Query] Execute: \(query)")

		do {
			// Parse the statement
			let statement = try SQLStatement(query)

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
					throw QueryError(message: "No username set or username is not a public key. Connect with username 'random' to have the server generate a new identity for you.")
				}

				guard let passwordKey = PrivateKey(string: password) else {
					throw QueryError(message: "The given password is not a valid private key.")
				}

				identity = Identity(publicKey: invokerKey, privateKey: passwordKey)
			}

			// Mutating statements are queued
			if statement.isMutating {
				// This needs to go to the ledger
				let counter = try node.ledger.longest.withUnverifiedTransactions { chain in
					return try chain.meta.users.counter(for: identity.publicKey) ?? 0
				}

				let transaction = try SQLTransaction(statement: statement, invoker: identity.publicKey, counter: counter + SQLTransaction.CounterType(1))
				try transaction.sign(with: identity.privateKey)
				try self.node.receive(transaction: transaction, from: nil)
				try connection.send(error: "OK \(transaction.counter) \(transaction.signature!.base58encoded) \(transaction.statement.sql(dialect: SQLStandardDialect()))", severity: .info)
			}
			else {
				try node.ledger.longest.withUnverifiedTransactions { chain in
					let context = SQLContext(metadata: chain.meta, invoker: identity.publicKey, block: chain.highest)
					let result = try chain.database.perform(statement.backendStatement(context: context).sql(dialect: chain.database.dialect))
					if case .row = result.state {
						// Send columns
						let fields = result.columns.map { col in
							return PQField(name: col, tableId: 0, columnId: 0, type: .text, typeModifier: 0)
						}
						try connection.send(description: fields)

						while case .row = result.state {
							let values = result.values.map { val in
								return val.pqValue
							}
							try connection.send(row: values)
							result.step()
						}
					}
					try connection.sendQueryComplete(tag: "SELECT")
				}
			}
		}
		catch {
			// TODO get some more information from the parser
			try? connection.send(error: error.localizedDescription)
		}
	}
}

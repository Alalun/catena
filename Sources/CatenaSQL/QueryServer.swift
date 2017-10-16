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
	var agent: SQLAgent

	public init(agent: SQLAgent, port: Int, family: Family = .ipv6) {
		self.agent = agent
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
				let transaction = try SQLTransaction(statement: statement, invoker: identity.publicKey, counter: SQLTransaction.CounterType(0))
				let result = try self.agent.submit(transaction: transaction, signWith: identity.privateKey)
				try connection.send(error: "\(result ? "OK" : "NOT OK") \(transaction.counter) \(transaction.signature!.base58encoded) \(transaction.statement.sql(dialect: SQLStandardDialect()))", severity: result ? .info : .error)
			}
			else {
				try self.agent.node.ledger.longest.withUnverifiedTransactions { chain in
					let context = SQLContext(metadata: chain.meta, invoker: identity.publicKey, block: chain.highest, parameterValues: [:])
					let ex = SQLExecutive(context: context, database: chain.database)
					let result = try ex.perform(statement)

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

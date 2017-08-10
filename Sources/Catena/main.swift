import Foundation
import class NetService.NetService
import protocol NetService.NetServiceDelegate
import Kitura
import CommandLineKit
import LoggerAPI
import HeliumLogger
import CatenaCore
import CatenaSQL
import class Socket.Socket

let databaseFileOption = StringOption(shortFlag: "d", longFlag: "database", required: false, helpMessage: "Backing database file (default: catena.sqlite)")
let memoryDatabaseFileOption = BoolOption(longFlag: "in-memory-database", helpMessage: "Use an in-memory (transient) database. Cannot be used with -d")
let seedOption = StringOption(shortFlag: "s", longFlag: "seed", required: false, helpMessage: "Genesis block seed string (default: empty)")
let helpOption = BoolOption(shortFlag: "h", longFlag: "help", helpMessage: "Show usage")
let netPortOption = IntOption(shortFlag: "p", longFlag: "gossip-port", helpMessage: "Listen port for peer-to-peer communications (default: 8338)")
let queryPortOption = IntOption(shortFlag: "q", longFlag: "query-port", helpMessage: "Listen port for query communications (default: networking port + 1)")
let peersOption = MultiStringOption(shortFlag: "j", longFlag: "join", helpMessage: "Peer URL to connect to ('ws://nodeid@hostname:port')")
let mineOption = BoolOption(shortFlag: "m", longFlag: "mine", helpMessage: "Enable mining of blocks")
let logOption = StringOption(shortFlag: "v", longFlag: "log", helpMessage: "The log level: debug, verbose, info, warning (default: info)")
let testOption = BoolOption(shortFlag: "t", longFlag: "test", helpMessage: "Submit test queries to the chain periodically (default: off)")
let initializeOption = BoolOption(shortFlag: "i", longFlag: "initialize", helpMessage: "Generate transactions to initialize basic database structure (default: false)")
let noReplayOption = BoolOption(shortFlag: "n", longFlag: "no-replay", helpMessage: "Do not replay database operations, just participate and validate transactions (default: false)")
let peerDatabaseFileOption = StringOption(longFlag: "peer-database", required: false, helpMessage: "Backing database file for peer database (default: catena-peers.sqlite)")
let noLocalPeersOption = BoolOption(longFlag: "no-local-discovery", helpMessage: "Disable local peer discovery")
let nodeUUIDOption = StringOption(longFlag: "node-uuid", required: false, helpMessage: "Set the node's UUID (default: a randomly generated UUID)")

let cli = CommandLineKit.CommandLine()
cli.addOptions(databaseFileOption, helpOption, seedOption, netPortOption, queryPortOption, peersOption, mineOption, logOption, testOption, initializeOption, noReplayOption, peerDatabaseFileOption, memoryDatabaseFileOption, noLocalPeersOption, nodeUUIDOption)

do {
	try cli.parse()
}
catch {
	cli.printUsage(error)
	exit(64) /* EX_USAGE */
}

// Print usage
if helpOption.wasSet {
	cli.printUsage()
	exit(0)
}

// Configure logging
let logLevel = logOption.value ?? "info"
let logLevelType: LoggerMessageType

switch logLevel {
	case "verbose": logLevelType = .verbose
	case "debug": logLevelType = .debug
	case "warning": logLevelType = .warning
	case "info": logLevelType = .info
	default: fatalError("Invalid setting for --log")
}

let logger = HeliumLogger(logLevelType)
logger.details = false
Log.logger = logger

// Generate genesis block
if memoryDatabaseFileOption.value && databaseFileOption.value != nil {
	fatalError("The -dm and -d flags cannot be set at the same time.")
}

// Generate root identity (not sure if we need this now)
// TODO: Persist identity
var rootCounter: SQLTransaction.CounterType = 0
let rootIdentity = try Identity()

// Initialize database if we have to
let databaseFile = memoryDatabaseFileOption.value ? ":memory:" : (databaseFileOption.value ?? "catena.sqlite")
let seedValue = seedOption.value ?? ""

do {
	// Find genesis block
	var genesisBlock = try SQLBlock.genesis(seed: seedValue, version: 1)
	genesisBlock.mine(difficulty: 10)
	Log.info("Genesis block=\(genesisBlock.debugDescription)) \(genesisBlock.isSignatureValid)")

	// If the database is in a file and we are initializing, remove anything that was there before
	if initializeOption.value && !memoryDatabaseFileOption.value {
		_ = unlink(databaseFile.cString(using: .utf8)!)
	}

	let uuid: UUID
	if let nu = nodeUUIDOption.value {
		if let nuuid = UUID(uuidString: nu) {
			uuid = nuuid
		}
		else {
			fatalError("Invalid value for --node-uuid option; needs to be a valid UUID")
		}
	}
	else {
		uuid = UUID()
	}

	let ledger = try SQLLedger(genesis: genesisBlock, database: databaseFile, replay: !noReplayOption.value)
	let netPort = netPortOption.value ?? 8338
	let node = try Node<SQLLedger>(ledger: ledger, port: netPort, miner: SHA256Hash(of: rootIdentity.publicKey.data), uuid: uuid)
	let _ = SQLAPIEndpoint(node: node, router: node.server.router)

	// Set up peer database
	let peerDatabaseFile = peerDatabaseFileOption.value ?? "catena-peers.sqlite"
	if !peerDatabaseFile.isEmpty {
		let peerDatabase = SQLiteDatabase()
		try peerDatabase.open(peerDatabaseFile)
		let peerTable = try SQLPeerDatabase(database: peerDatabase, table: SQLTable(name: "peers"))

		// Add peers from database
		for p in try peerTable.peers() {
			node.add(peer: p)
		}

		node.peerDatabase = peerTable
	}

	// Add peers from command line
	for p in peersOption.value ?? [] {
		if let u = URL(string: p) {
			node.add(peer: u)
		}
	}

	// Query server
	let queryServerV4 = NodeQueryServer(node: node, port: queryPortOption.value ?? (netPort+1), family: .ipv4)
	let queryServerV6 = NodeQueryServer(node: node, port: queryPortOption.value ?? (netPort+1), family: .ipv6)
	queryServerV6.run()
	queryServerV4.run()

	node.miner.isEnabled = mineOption.value
	node.announceLocally = !noLocalPeersOption.value
	node.discoverLocally = !noLocalPeersOption.value

	Log.info("Node URL: \(node.url)")

	if initializeOption.value {
		// Generate root keypair

		Log.info("Root private key: \(rootIdentity.privateKey.stringValue)")
		Log.info("Root public key: \(rootIdentity.publicKey.stringValue)")
		Swift.print("\r\nPGPASSWORD=\(rootIdentity.privateKey.stringValue) psql -h localhost -p \(netPort+1) -U \(rootIdentity.publicKey.stringValue)\r\n")

		// Create grants table, etc.
		let create = SQLStatement.create(table: SQLTable(name: SQLMetadata.grantsTableName), schema: SQLGrants.schema)
		let createTransaction = try SQLTransaction(statement: create, invoker: rootIdentity.publicKey, counter: rootCounter)
		rootCounter += 1

		let grant = SQLStatement.insert(SQLInsert(
			orReplace: false,
			into: SQLTable(name: SQLMetadata.grantsTableName),
			columns: ["user", "kind", "table"].map { SQLColumn(name: $0) },
			values: [
				[.literalBlob(rootIdentity.publicKey.data.sha256), .literalString(SQLPrivilege.Kind.create.rawValue), .null],
				[.literalBlob(rootIdentity.publicKey.data.sha256), .literalString(SQLPrivilege.Kind.drop.rawValue), .null],
				[.literalBlob(rootIdentity.publicKey.data.sha256), .literalString(SQLPrivilege.Kind.insert.rawValue), .literalString(SQLMetadata.grantsTableName)],
				[.literalBlob(rootIdentity.publicKey.data.sha256), .literalString(SQLPrivilege.Kind.delete.rawValue), .literalString(SQLMetadata.grantsTableName)]
			]
		))
		let grantTransaction = try SQLTransaction(statement: grant, invoker: rootIdentity.publicKey, counter: rootCounter)
		rootCounter += 1

		try node.receive(transaction: try createTransaction.sign(with: rootIdentity.privateKey), from: nil)
		try node.receive(transaction: try grantTransaction.sign(with: rootIdentity.privateKey), from: nil)
	}

	// Start submitting test blocks if that's what the user requested
	if testOption.value {
		let identity = try Identity()

		node.start(blocking: false)
		let q = try SQLStatement("CREATE TABLE test (origin TEXT, x TEXT);");
		try node.receive(transaction: try SQLTransaction(statement: q, invoker: rootIdentity.publicKey, counter: rootCounter).sign(with: rootIdentity.privateKey), from: nil)
		rootCounter += 1

		// Grant to user
		let grant = SQLStatement.insert(SQLInsert(
			orReplace: false,
			into: SQLTable(name: SQLMetadata.grantsTableName),
			columns: ["user", "kind", "table"].map { SQLColumn(name: $0) },
			values: [
				[.literalBlob(identity.publicKey.data.sha256), .literalString(SQLPrivilege.Kind.insert.rawValue), .literalString("test")]
			]
		))
		try node.receive(transaction: try SQLTransaction(statement: grant, invoker: rootIdentity.publicKey, counter: rootCounter).sign(with: rootIdentity.privateKey), from: nil)
		rootCounter += 1

		sleep(10)

		Log.info("Start submitting demo blocks")
		var testCounter: SQLTransaction.CounterType = 0
		do {
			var i = 0
			while true {
				i += 1
				let q = try SQLStatement("INSERT INTO test (origin,x) VALUES ('\(node.uuid.uuidString)',\(i));")
				let tr = try SQLTransaction(statement: q, invoker: identity.publicKey, counter: testCounter).sign(with: identity.privateKey)
				Log.info("[Test] submit \(tr)")
				try node.receive(transaction: tr, from: nil)
				testCounter += 1
				sleep(2)
			}
		}
		catch {
			Log.error(error.localizedDescription)
		}
	}
	else {
		node.start(blocking: false)
	}

	withExtendedLifetime(node) {
		RunLoop.main.run()
	}
}
catch {
	Log.error(error.localizedDescription)
}
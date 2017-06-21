import Foundation
import LoggerAPI
import SwiftParser

struct SQLTable: Equatable, Hashable {
	var name: String

	func sql(dialect: SQLDialect) -> String {
		return name.lowercased()
	}

	var hashValue: Int {
		return self.name.lowercased().hashValue
	}

	static func ==(lhs: SQLTable, rhs: SQLTable) -> Bool {
		return lhs.name.lowercased() == rhs.name.lowercased()
	}
}

struct SQLColumn: Equatable, Hashable {
	var name: String

	func sql(dialect: SQLDialect) -> String {
		return dialect.columnIdentifier(name.lowercased())
	}

	var hashValue: Int {
		return self.name.lowercased().hashValue
	}

	static func ==(lhs: SQLColumn, rhs: SQLColumn) -> Bool {
		return lhs.name.lowercased() == rhs.name.lowercased()
	}
}

enum SQLType {
	case text
	case int
	case blob

	func sql(dialect: SQLDialect) -> String {
		switch self {
		case .text: return "TEXT"
		case .int: return "INT"
		case .blob: return "BLOB"
		}
	}
}

struct SQLSchema {
	var columns = OrderedDictionary<SQLColumn, SQLType>()
	var primaryKey: SQLColumn? = nil

	init(columns: OrderedDictionary<SQLColumn, SQLType>, primaryKey: SQLColumn? = nil) {
		self.columns = columns
		self.primaryKey = primaryKey
	}

	init(primaryKey: SQLColumn? = nil, columns: (SQLColumn, SQLType)...) {
		self.primaryKey = primaryKey
		for c in columns {
			self.columns.append(c.1, forKey: c.0)
		}
	}
}

enum SQLJoin {
	case left(table: SQLTable, on: SQLExpression)

	func sql(dialect: SQLDialect) -> String {
		switch self {
		case .left(table: let t, on: let on):
			return "LEFT JOIN \(t.sql(dialect: dialect)) ON \(on.sql(dialect: dialect))"
		}
	}
}

struct SQLSelect {
	var these: [SQLExpression] = []
	var from: SQLTable? = nil
	var joins: [SQLJoin] = []
	var `where`: SQLExpression? = nil
	var distinct: Bool = false
}

struct SQLInsert {
	var orReplace: Bool = false
	var into: SQLTable
	var columns: [SQLColumn] = []
	var values: [[SQLExpression]] = []
}

struct SQLUpdate {
	var table: SQLTable
	var set: [SQLColumn: SQLExpression] = [:]
	var `where`: SQLExpression? = nil

	init(table: SQLTable) {
		self.table = table
	}
}

enum SQLStatement {
	case create(table: SQLTable, schema: SQLSchema)
	case delete(from: SQLTable, where: SQLExpression?)
	case drop(table: SQLTable)
	case insert(SQLInsert)
	case select(SQLSelect)
	case update(SQLUpdate)

	enum SQLStatementError: LocalizedError {
		case syntaxError(query: String)
		case invalidRootError

		var errorDescription: String? {
			switch self {
			case .syntaxError(query: let q): return "syntax error: '\(q)'"
			case .invalidRootError: return "invalid root statement for query"
			}
		}
	}

	init(_ sql: String) throws {
		let parser = SQLParser()
		if !parser.parse(sql) {
			throw SQLStatementError.syntaxError(query: sql)
		}

		// Top-level item must be a statement
		guard let root = parser.root, case .statement(let statement) = root else {
			throw SQLStatementError.invalidRootError
		}

		self = statement
	}

	var isMutating: Bool {
		switch self {
		case .create, .drop, .delete, .update, .insert(_):
			return true

		case .select(_):
			return false
		}
	}

	func sql(dialect: SQLDialect) -> String {
		switch self {
		case .create(table: let table, schema: let schema):
			let def = schema.columns.map { (col, type) -> String in
				let primary = (schema.primaryKey == col) ? " PRIMARY KEY" : ""
				return "\(col.sql(dialect:dialect)) \(type.sql(dialect: dialect))\(primary)"
			}

			return "CREATE TABLE \(table.sql(dialect: dialect)) (\(def.joined(separator: ", ")));"

		case .delete(from: let table, where: let expression):
			let whereSQL: String
			if let w = expression {
				whereSQL = " WHERE \(w.sql(dialect: dialect))";
			}
			else {
				whereSQL = "";
			}
			return "DELETE FROM \(table.sql(dialect: dialect))\(whereSQL);"

		case .drop(let table):
			return "DROP TABLE \(table.sql(dialect: dialect));"

		case .insert(let insert):
			let colSQL = insert.columns.map { $0.sql(dialect: dialect) }.joined(separator: ", ")
			let tupleSQL = insert.values.map { tuple in
				let ts = tuple.map { $0.sql(dialect: dialect) }.joined(separator: ",")
				return "(\(ts))"
				}.joined(separator: ", ")

			let orReplaceSQL = insert.orReplace ? " OR REPLACE" : ""
			return "INSERT\(orReplaceSQL) INTO \(insert.into.sql(dialect: dialect)) (\(colSQL)) VALUES \(tupleSQL);"

		case .update(let update):
			if update.set.isEmpty {
				return "UPDATE;";
			}
			var updateSQL: [String] = [];
			for (col, expr) in update.set {
				updateSQL.append("\(col.sql(dialect: dialect)) = \(expr.sql(dialect: dialect))")
			}

			let whereSQL: String
			if let w = update.where {
				whereSQL = " WHERE \(w.sql(dialect: dialect))"
			}
			else {
				whereSQL = ""
			}

			return "UPDATE \(update.table.sql(dialect: dialect)) SET \(updateSQL.joined(separator: ", "))\(whereSQL);"

		case .select(let select):
			let selectList = select.these.map { $0.sql(dialect: dialect) }.joined(separator: ", ")
			let distinctSQL = select.distinct ? " DISTINCT" : ""

			if let t = select.from {
				// Joins
				let joinSQL = select.joins.map { " " + $0.sql(dialect: dialect) }.joined(separator: " ")

				// Where conditions
				let whereSQL: String
				if let w = select.where {
					whereSQL = " WHERE \(w.sql(dialect: dialect))"
				}
				else {
					whereSQL = ""
				}

				return "SELECT\(distinctSQL) \(selectList) FROM \(t.sql(dialect: dialect))\(joinSQL)\(whereSQL);"
			}
			else {
				return "SELECT\(distinctSQL) \(selectList);"
			}
		}
	}
}

enum SQLUnary {
	case isNull
	case negate
	case not
	case abs

	func sql(expression: String, dialect: SQLDialect) -> String {
		switch self {
		case .isNull: return "(\(expression)) IS NULL"
		case .not: return "NOT(\(expression))"
		case .abs: return "ABS(\(expression))"
		case .negate: return "-(\(expression))"
		}
	}
}

enum SQLBinary {
	case equals
	case notEquals
	case lessThan
	case greaterThan
	case lessThanOrEqual
	case greaterThanOrEqual
	case and
	case or
	case add
	case subtract
	case multiply
	case divide
	case concatenate

	func sql(dialect: SQLDialect) -> String {
		switch self {
		case .equals: return "="
		case .notEquals: return "<>"
		case .lessThan: return "<"
		case .greaterThan: return ">"
		case .lessThanOrEqual: return "<="
		case .greaterThanOrEqual: return ">="
		case .and: return "AND"
		case .or: return "OR"
		case .add: return "+"
		case .subtract: return "-"
		case .divide: return "/"
		case .multiply: return "*"
		case .concatenate: return "||"
		}
	}
}

enum SQLExpression {
	case literalInteger(Int)
	case literalString(String)
	case literalBlob(Data)
	case column(SQLColumn)
	case allColumns
	case null
	case variable(String)
	indirect case binary(SQLExpression, SQLBinary, SQLExpression)
	indirect case unary(SQLUnary, SQLExpression)

	func sql(dialect: SQLDialect) -> String {
		switch self {
		case .literalString(let s):
			return dialect.literalString(s)

		case .literalInteger(let i):
			return "\(i)"

		case .literalBlob(let d):
			return dialect.literalBlob(d)

		case .column(let c):
			return c.sql(dialect: dialect)

		case .allColumns:
			return "*"

		case .null:
			return "NULL"

		case .variable(let v):
			return "$\(v)"

		case .binary(let left, let binary, let right):
			return "(\(left.sql(dialect: dialect)) \(binary.sql(dialect: dialect)) \(right.sql(dialect: dialect)))"

		case .unary(let unary, let ex):
			return unary.sql(expression: ex.sql(dialect: dialect), dialect: dialect)
		}
	}
}

enum SQLFragment {
	case statement(SQLStatement)
	case expression(SQLExpression)
	case tuple([SQLExpression])
	case columnList([SQLColumn])
	case tableIdentifier(SQLTable)
	case columnIdentifier(SQLColumn)
	case type(SQLType)
	case columnDefinition(column: SQLColumn, type: SQLType, primary: Bool)
	case binaryOperator(SQLBinary)
	case unaryOperator(SQLUnary)
	case join(SQLJoin)
}

internal class SQLParser: Parser, CustomDebugStringConvertible {
	private var stack: [SQLFragment] = []
	private var error = false

	private func pushLiteralString() {
		// TODO: escaping
		self.stack.append(.expression(.literalString(self.text)))
	}

	private func pushLiteralBlob() {
		if let s = self.text.hexDecoded {
			self.stack.append(.expression(.literalBlob(s)))
		}
		else {
			self.stack.append(.expression(.null))
			self.error = true
		}
	}

	var debugDescription: String {
		return "\(self.stack)"
	}

	var root: SQLFragment? {
		return self.error ? nil : self.stack.last
	}

	public override func rules() {
		// Literals
		let firstCharacter: ParserRule = (("a"-"z")|("A"-"Z"))
		let followingCharacter: ParserRule = (firstCharacter | ("0"-"9") | literal("_"))
		add_named_rule("lit-int", rule: (Parser.matchLiteral("-")/~ ~ ("0"-"9")+) => {
			if let n = Int(self.text) {
				self.stack.append(.expression(.literalInteger(n)))
			}
		})

		add_named_rule("lit-null", rule: Parser.matchLiteralInsensitive("NULL") => {
			self.stack.append(.expression(.null))
		})

		add_named_rule("lit-variable", rule: Parser.matchLiteral("$") ~ ((firstCharacter ~ (followingCharacter*)/~) => {
			self.stack.append(.expression(.variable(self.text)))
		}))

		add_named_rule("lit-column-naked", rule: (firstCharacter ~ (followingCharacter*)/~) => {
			self.stack.append(.columnIdentifier(SQLColumn(name: self.text)))
		})

		add_named_rule("lit-column", rule: (Parser.matchLiteral("\"") ~ ^"lit-column-naked" ~ Parser.matchLiteral("\"")) | ^"lit-column-naked")

		add_named_rule("lit-all-columns", rule: Parser.matchLiteral("*") => {
			self.stack.append(.expression(.allColumns))
		})

		add_named_rule("lit-blob", rule: Parser.matchLiteral("X'") ~ Parser.matchAnyCharacterExcept([Character("'")])* => pushLiteralBlob ~ Parser.matchLiteral("'"))

		add_named_rule("lit-string", rule: Parser.matchLiteral("'") ~ Parser.matchAnyCharacterExcept([Character("'")])* => pushLiteralString ~ Parser.matchLiteral("'"))
		add_named_rule("lit", rule:
			^"lit-int"
			| ^"lit-all-columns"
			| ^"lit-variable"
			| ^"lit-blob"
			| ^"lit-string"
			| ^"lit-null"
			| (^"lit-column" => {
				guard case .columnIdentifier(let c) = self.stack.popLast()! else { fatalError() }
				self.stack.append(.expression(.column(c)))
			  })
			)

		// Expressions
		add_named_rule("ex-sub", rule: Parser.matchLiteral("(") ~~ ^"ex" ~~ Parser.matchLiteral(")"))

		add_named_rule("ex-unary-postfix", rule: Parser.matchLiteralInsensitive("IS NULL") => {
			guard case .expression(let right) = self.stack.popLast()! else { fatalError() }
			self.stack.append(.expression(SQLExpression.unary(.isNull, right)))
		})

		add_named_rule("ex-unary", rule: ^"lit" ~~ (^"ex-unary-postfix")/~)

		add_named_rule("ex-value", rule: ^"ex-unary" | ^"ex-sub")

		add_named_rule("ex-equality-operator", rule: Parser.matchAnyFrom(["=", "<>", "<=", ">=", "<", ">"].map { Parser.matchLiteral($0) }) => {
			switch self.text {
			case "=": self.stack.append(.binaryOperator(.equals))
			case "<>": self.stack.append(.binaryOperator(.notEquals))
			case "<=": self.stack.append(.binaryOperator(.lessThanOrEqual))
			case ">=": self.stack.append(.binaryOperator(.greaterThanOrEqual))
			case "<": self.stack.append(.binaryOperator(.lessThan))
			case ">": self.stack.append(.binaryOperator(.greaterThan))
			default: fatalError()
			}
		})

		add_named_rule("ex-prefix-operator", rule: Parser.matchAnyFrom(["-"].map { Parser.matchLiteral($0) }) => {
			switch self.text {
			case "-": self.stack.append(.unaryOperator(.negate))
			default: fatalError()
			}
		})

		add_named_rule("ex-prefix-call", rule: Parser.matchAnyFrom(["NOT", "ABS"].map { Parser.matchLiteral($0) }) => {
			switch self.text {
			case "NOT": self.stack.append(.unaryOperator(.not))
			case "ABS": self.stack.append(.unaryOperator(.abs))
			default: fatalError()
			}
		})

		add_named_rule("ex-math-addition-operator", rule: Parser.matchAnyFrom(["+", "-", "||"].map { Parser.matchLiteral($0) }) => {
			switch self.text {
			case "+": self.stack.append(.binaryOperator(.add))
			case "-": self.stack.append(.binaryOperator(.subtract))
			case "||": self.stack.append(.binaryOperator(.concatenate))
			default: fatalError()
			}
		})

		add_named_rule("ex-math-multiplication-operator", rule: Parser.matchAnyFrom(["*", "/"].map { Parser.matchLiteral($0) }) => {
			switch self.text {
			case "*": self.stack.append(.binaryOperator(.multiply))
			case "/": self.stack.append(.binaryOperator(.divide))
			default: fatalError()
			}
		})

		add_named_rule("ex-unary-prefix", rule: (
			((^"ex-prefix-operator" ~~ ^"ex-value") => {
				guard case .expression(let expr) = self.stack.popLast()! else { fatalError() }
				guard case .unaryOperator(let op) = self.stack.popLast()! else { fatalError() }
				self.stack.append(.expression(.unary(op, expr)))
			})
			| ((^"ex-prefix-call" ~~ ^"ex-sub") => {
				guard case .expression(let expr) = self.stack.popLast()! else { fatalError() }
				guard case .unaryOperator(let op) = self.stack.popLast()! else { fatalError() }
				self.stack.append(.expression(.unary(op, expr)))
			})
			| ^"ex-value"))

		add_named_rule("ex-math-multiplication", rule: ^"ex-unary-prefix" ~~ ((^"ex-math-multiplication-operator" ~~ ^"ex-unary-prefix") => {
			guard case .expression(let right) = self.stack.popLast()! else { fatalError() }
			guard case .binaryOperator(let op) = self.stack.popLast()! else { fatalError() }
			guard case .expression(let left) = self.stack.popLast()! else { fatalError() }
			self.stack.append(.expression(.binary(left, op, right)))
		})*)

		add_named_rule("ex-math-addition", rule: ^"ex-math-multiplication" ~~ ((^"ex-math-addition-operator" ~~ ^"ex-math-multiplication") => {
			guard case .expression(let right) = self.stack.popLast()! else { fatalError() }
			guard case .binaryOperator(let op) = self.stack.popLast()! else { fatalError() }
			guard case .expression(let left) = self.stack.popLast()! else { fatalError() }
			self.stack.append(.expression(.binary(left, op, right)))
			})*)

		add_named_rule("ex-equality", rule: ^"ex-math-addition" ~~ ((^"ex-equality-operator" ~~ ^"ex-math-addition") => {
			guard case .expression(let right) = self.stack.popLast()! else { fatalError() }
			guard case .binaryOperator(let op) = self.stack.popLast()! else { fatalError() }
			guard case .expression(let left) = self.stack.popLast()! else { fatalError() }
			self.stack.append(.expression(.binary(left, op, right)))
		})/~)

		add_named_rule("ex", rule: ^"ex-equality")

		// Types
		add_named_rule("type-text", rule: Parser.matchLiteralInsensitive("TEXT") => { self.stack.append(.type(SQLType.text)) })
		add_named_rule("type-int", rule: Parser.matchLiteralInsensitive("INT") => { self.stack.append(.type(SQLType.int)) })
		add_named_rule("type-blob", rule: Parser.matchLiteralInsensitive("BLOB") => { self.stack.append(.type(SQLType.blob)) })
		add_named_rule("type", rule: ^"type-text" | ^"type-int" | ^"type-blob")

		// Column definition
		add_named_rule("column-definition", rule: ((^"lit-column" ~~ ^"type") => {
				guard case .type(let t) = self.stack.popLast()! else { fatalError() }
				guard case .columnIdentifier(let c) = self.stack.popLast()! else { fatalError() }
				self.stack.append(.columnDefinition(column: c, type: t, primary: false))
			})
			~~ (Parser.matchLiteralInsensitive("PRIMARY KEY") => {
				guard case .columnDefinition(column: let c, type: let t, primary: let p) = self.stack.popLast()! else { fatalError() }
				self.stack.append(.columnDefinition(column: c, type: t, primary: p))
			})/~)

		// FROM
		add_named_rule("id-table", rule: firstCharacter ~ followingCharacter*)

		// SELECT
		add_named_rule("tuple", rule: Parser.matchList(^"ex" => {
			if case .expression(let ne) = self.stack.popLast()! {
				if let last = self.stack.last, case .tuple(let exprs) = last {
					_ = self.stack.popLast()
					self.stack.append(.tuple(exprs + [ne]))
				}
				else {
					self.stack.append(.tuple([ne]))
				}
			}
		}, separator: Parser.matchLiteral(",")))

		// INSERT
		add_named_rule("column-list", rule: Parser.matchList(^"lit-column" => {
			if case .columnIdentifier(let colName) = self.stack.popLast()! {
				if let last = self.stack.popLast(), case .columnList(let exprs) = last {
					self.stack.append(.columnList(exprs + [colName]))
				}
				else {
					self.stack.append(.columnList([colName]))
				}
			}
			else {
				// This cannot be
				fatalError("Parser programming error")
			}
			}, separator: Parser.matchLiteral(",")))


		// Statement types
		add_named_rule("select-dql-statement", rule:
			Parser.matchLiteralInsensitive("SELECT") => {
				self.stack.append(.statement(.select(SQLSelect())))
			}
			~~ ((Parser.matchLiteralInsensitive("DISTINCT") => {
				guard case .statement(let st) = self.stack.popLast()! else { fatalError() }
				guard case .select(var select) = st else { fatalError() }
				select.distinct = true
				self.stack.append(.statement(.select(select)))
			})/~)
			~~ (^"tuple" => {
				guard case .tuple(let exprs) = self.stack.popLast()! else { fatalError() }
				guard case .statement(let st) = self.stack.popLast()! else { fatalError() }
				guard case .select(var select) = st else { fatalError() }
				select.these = exprs
				self.stack.append(.statement(.select(select)))
			})
			~~ (
					Parser.matchLiteralInsensitive("FROM") ~~ ^"id-table" => {
						guard case .statement(let st) = self.stack.popLast()! else { fatalError() }
						guard case .select(var select) = st else { fatalError() }
						select.from = SQLTable(name: self.text)
						self.stack.append(.statement(.select(select)))
					}
					~~ ((Parser.matchLiteralInsensitive("LEFT JOIN") => {
							self.stack.append(.join(.left(table: SQLTable(name: ""), on: SQLExpression.null)))
						}
						~~ ^"id-table" => {
							guard case .join(let join) = self.stack.popLast()! else { fatalError() }
							guard case .left(table: _, on: _) = join else { fatalError() }
							self.stack.append(.join(.left(table: SQLTable(name: self.text), on: SQLExpression.null)))
						}
						~~ Parser.matchLiteralInsensitive("ON")
						~~ ^"ex" => {
							guard case .expression(let expression) = self.stack.popLast()! else { fatalError() }
							guard case .join(let join) = self.stack.popLast()! else { fatalError() }
							guard case .left(table: let table, on: _) = join else { fatalError() }
							self.stack.append(.join(.left(table: table, on: expression)))
						}) => {
							guard case .join(let join) = self.stack.popLast()! else { fatalError() }
							guard case .statement(let st) = self.stack.popLast()! else { fatalError() }
							guard case .select(var select) = st else { fatalError() }
							select.joins.append(join)
							self.stack.append(.statement(.select(select)))
						})*
					~~ (Parser.matchLiteralInsensitive("WHERE") ~~ ^"ex" => {
						guard case .expression(let expression) = self.stack.popLast()! else { fatalError() }
						guard case .statement(let st) = self.stack.popLast()! else { fatalError() }
						guard case .select(var select) = st else { fatalError() }
						select.where = expression
						self.stack.append(.statement(.select(select)))
					})/~
				)/~
		)

		add_named_rule("create-ddl-statement", rule: Parser.matchLiteralInsensitive("CREATE TABLE")
			~~ (^"id-table" => {
					self.stack.append(.statement(.create(table: SQLTable(name: self.text), schema: SQLSchema())))
				})
			~~ Parser.matchLiteral("(")
			~~ Parser.matchList(^"column-definition" => {
				guard case .columnDefinition(column: let column, type: let type, primary: let primary) = self.stack.popLast()! else { fatalError() }
				guard case .statement(let s) = self.stack.popLast()! else { fatalError() }
				guard case .create(table: let t, schema: let oldSchema) = s else { fatalError() }
				var newSchema = oldSchema
				newSchema.columns[column] = type
				if primary {
					newSchema.primaryKey = column
				}
				self.stack.append(.statement(.create(table: t, schema: newSchema)))
			}, separator: Parser.matchLiteral(","))
			~~ Parser.matchLiteral(")")
		)

		add_named_rule("drop-ddl-statement", rule: Parser.matchLiteralInsensitive("DROP TABLE")
			~~ (^"id-table" => {
				self.stack.append(.statement(.drop(table: SQLTable(name: self.text))))
			})
		)

		add_named_rule("update-dml-statement", rule: Parser.matchLiteralInsensitive("UPDATE")
			~~ (^"id-table" => {
				let update = SQLUpdate(table: SQLTable(name: self.text))
				self.stack.append(.statement(.update(update)))
			})
			~~ Parser.matchLiteralInsensitive("SET")
			~~ Parser.matchList(^"lit-column"
				~~ Parser.matchLiteral("=")
				~~ ^"ex" => {
					guard case .expression(let expression) = self.stack.popLast()! else { fatalError() }
					guard case .columnIdentifier(let col) = self.stack.popLast()! else { fatalError() }
					guard case .statement(let st) = self.stack.popLast()! else { fatalError() }
					guard case .update(var update) = st else { fatalError() }
					if update.set[col] != nil {
						// Same column named twice, that is not allowed
						self.error = true
					}
					update.set[col] = expression
					self.stack.append(.statement(.update(update)))
				}, separator: Parser.matchLiteral(","))
			~~ (Parser.matchLiteralInsensitive("WHERE") ~~ (^"ex" => {
				guard case .expression(let expression) = self.stack.popLast()! else { fatalError() }
				guard case .statement(let st) = self.stack.popLast()! else { fatalError() }
				guard case .update(var update) = st else { fatalError() }
				update.where = expression
				self.stack.append(.statement(.update(update)))
			}))/~)

		add_named_rule("delete-dml-statement", rule: Parser.matchLiteralInsensitive("DELETE FROM")
			~~ (^"id-table" => {
				self.stack.append(.statement(.delete(from: SQLTable(name: self.text), where: nil)))
			})
			~~ (Parser.matchLiteralInsensitive("WHERE") ~~ ^"ex" => {
				guard case .expression(let expression) = self.stack.popLast()! else { fatalError() }
				guard case .statement(let st) = self.stack.popLast()! else { fatalError() }
				guard case .delete(from: let table, where: _) = st else { fatalError() }
				self.stack.append(.statement(.delete(from:table, where: expression)))
			})/~
		)

		add_named_rule("insert-dml-statement", rule: (
				Parser.matchLiteralInsensitive("INSERT") => {
					self.stack.append(.statement(.insert(SQLInsert(orReplace: false, into: SQLTable(name: ""), columns: [], values: []))))
				}
				~~ ((Parser.matchLiteralInsensitive("OR REPLACE") => {
					guard case .statement(let statement) = self.stack.popLast()! else { fatalError() }
					guard case .insert(var insert) = statement else { fatalError() }
					insert.orReplace = true
					self.stack.append(.statement(.insert(insert)))
				})/~)
				~~ Parser.matchLiteralInsensitive("INTO")
				~~ (^"id-table" => { self.stack.append(.tableIdentifier(SQLTable(name: self.text))) })
				~~ ((Parser.matchLiteral("(") => { self.stack.append(.columnList([])) }) ~~ ^"column-list" ~~ Parser.matchLiteral(")"))
				~~ Parser.matchLiteralInsensitive("VALUES")
					=> {
						guard case .columnList(let cs) = self.stack.popLast()! else { fatalError() }
						guard case .tableIdentifier(let tn) = self.stack.popLast()! else { fatalError() }
						guard case .statement(let statement) = self.stack.popLast()! else { fatalError() }
						guard case .insert(var insert) = statement else { fatalError() }
						insert.into = tn
						insert.columns = cs
						insert.values = []
						self.stack.append(.statement(.insert(insert)))
					}
				~~ Parser.matchList(((Parser.matchLiteral("(") => { self.stack.append(.tuple([])) }) ~~ ^"tuple" ~~ Parser.matchLiteral(")"))
					=> {
						guard case .tuple(let rs) = self.stack.popLast()! else { fatalError() }
						guard case .statement(let statement) = self.stack.popLast()! else { fatalError() }
						guard case .insert(var insert) = statement else { fatalError() }
						insert.values.append(rs)
						self.stack.append(.statement(.insert(insert)))
					}, separator: Parser.matchLiteral(","))
			))

		// Statement categories
		add_named_rule("dql-statement", rule: ^"select-dql-statement")
		add_named_rule("ddl-statement", rule: ^"create-ddl-statement" | ^"drop-ddl-statement")
		add_named_rule("dml-statement", rule: ^"update-dml-statement" | ^"insert-dml-statement" | ^"delete-dml-statement")

		// Statement
		add_named_rule("statement", rule: (^"ddl-statement" | ^"dml-statement" | ^"dql-statement") ~~ Parser.matchLiteral(";"))
		start_rule = (^"statement")*!*
	}
}

fileprivate extension Parser {
	static func matchEOF() -> ParserRule {
		return {(parser: Parser, reader: Reader) -> Bool in
			return reader.eof()
		}
	}

	static func matchAnyCharacterExcept(_ characters: [Character]) -> ParserRule {
		return {(parser: Parser, reader: Reader) -> Bool in
			if reader.eof() {
				return false
			}

			let pos = reader.position
			let ch = reader.read()
			for exceptedCharacter in characters {
				if ch==exceptedCharacter {
					reader.seek(pos)
					return false
				}
			}
			return true
		}
	}

	static func matchAnyFrom(_ rules: [ParserRule]) -> ParserRule {
		return {(parser: Parser, reader: Reader) -> Bool in
			let pos = reader.position
			for rule in rules {
				if(rule(parser, reader)) {
					return true
				}
				reader.seek(pos)
			}

			return false
		}
	}

	static func matchList(_ item: @escaping ParserRule, separator: @escaping ParserRule) -> ParserRule {
		return item ~~ (separator ~~ item)*
	}

	static func matchLiteralInsensitive(_ string:String) -> ParserRule {
		return {(parser: Parser, reader: Reader) -> Bool in
			let pos = reader.position

			for ch in string.characters {
				let flag = (String(ch).caseInsensitiveCompare(String(reader.read())) == ComparisonResult.orderedSame)

				if !flag {
					reader.seek(pos)
					return false
				}
			}
			return true
		}
	}

	static func matchLiteral(_ string:String) -> ParserRule {
		return {(parser: Parser, reader: Reader) -> Bool in
			let pos = reader.position

			for ch in string.characters {
				if ch != reader.read() {
					reader.seek(pos)
					return false
				}
			}
			return true
		}
	}
}

/** The visitor can be used to analyze and rewrite SQL expressions. Call .visit on the element to visit and supply an
SQLVisitor instance. By returning a different object than the one passed into a `visit` call, you can modify the source
expression. For items that have visitable children, the children will be visited first, and then visit will be called
for the parent with the updated children (if applicable). */
protocol SQLVisitor {
	func visit(column: SQLColumn) throws -> SQLColumn
	func visit(expression: SQLExpression) throws -> SQLExpression
	func visit(table: SQLTable) throws -> SQLTable
	func visit(binary: SQLBinary) throws -> SQLBinary
	func visit(unary: SQLUnary) throws -> SQLUnary
	func visit(statement: SQLStatement) throws -> SQLStatement
	func visit(schema: SQLSchema) throws -> SQLSchema
	func visit(join: SQLJoin) throws -> SQLJoin
}

extension SQLVisitor {
	// By default, a visitor does not modify anything
	func visit(unary: SQLUnary) throws -> SQLUnary { return unary }
	func visit(binary: SQLBinary) throws -> SQLBinary { return binary }
	func visit(column: SQLColumn) throws -> SQLColumn { return column }
	func visit(expression: SQLExpression) throws -> SQLExpression { return expression }
	func visit(table: SQLTable) throws -> SQLTable { return table }
	func visit(statement: SQLStatement) throws -> SQLStatement { return statement }
	func visit(schema: SQLSchema) throws -> SQLSchema { return schema }
	func visit(join: SQLJoin) throws -> SQLJoin { return join }
}

extension SQLColumn {
	func visit(_ visitor: SQLVisitor) throws -> SQLColumn {
		return try visitor.visit(column: self)
	}
}

extension SQLBinary {
	func visit(_ visitor: SQLVisitor) throws -> SQLBinary {
		return try visitor.visit(binary: self)
	}
}

extension SQLUnary {
	func visit(_ visitor: SQLVisitor) throws -> SQLUnary {
		return try visitor.visit(unary: self)
	}
}

extension SQLTable {
	func visit(_ visitor: SQLVisitor) throws -> SQLTable {
		return try visitor.visit(table: self)
	}
}

extension SQLJoin {
	func visit(_ visitor: SQLVisitor) throws -> SQLJoin {
		let newSelf: SQLJoin
		switch self {
		case .left(table: let t, on: let ex):
			newSelf = .left(table: try t.visit(visitor), on: try ex.visit(visitor))
		}

		return try visitor.visit(join: newSelf)
	}
}

extension SQLSchema {
	func visit(_ visitor: SQLVisitor) throws -> SQLSchema {
		var cols = OrderedDictionary<SQLColumn, SQLType>()
		try self.columns.forEach { col, type in
			cols[try col.visit(visitor)] = type
		}

		let newSelf = SQLSchema(columns: cols, primaryKey: try self.primaryKey?.visit(visitor))
		return try visitor.visit(schema: newSelf)
	}
}

extension SQLStatement {
	func visit(_ visitor: SQLVisitor) throws -> SQLStatement {
		let newSelf: SQLStatement

		switch self {
		case .create(table: let t, schema: let s):
			newSelf = .create(table: try t.visit(visitor), schema: try s.visit(visitor))

		case .delete(from: let table, where: let expr):
			newSelf = .delete(from: try table.visit(visitor), where: try expr?.visit(visitor))

		case .drop(table: let t):
			newSelf = .drop(table: try t.visit(visitor))

		case .insert(var ins):
			ins.columns = try ins.columns.map { try $0.visit(visitor) }
			ins.values = try ins.values.map { tuple in
				return try tuple.map { expr in
					return try expr.visit(visitor)
				}
			}
			newSelf = .insert(ins)

		case .select(var s):
			s.from = try s.from?.visit(visitor)
			s.joins = try s.joins.map { try $0.visit(visitor) }
			s.these = try s.these.map { try $0.visit(visitor) }
			s.where = try s.where?.visit(visitor)
			newSelf = .select(s)

		case .update(var u):
			u.table = try u.table.visit(visitor)
			u.where = try u.where?.visit(visitor)

			var newSet: [SQLColumn: SQLExpression] = [:]
			try u.set.forEach { (col, expr) in
				newSet[try col.visit(visitor)] = try expr.visit(visitor)
			}
			u.set = newSet
			newSelf = .update(u)
		}

		return try visitor.visit(statement: newSelf)
	}
}

extension SQLExpression {
	func visit(_ visitor: SQLVisitor) throws -> SQLExpression {
		let newSelf: SQLExpression

		switch self {
		case .allColumns, .null, .literalInteger(_), .literalString(_), .literalBlob(_), .variable(_):
			// Literals are not currently visited separately
			newSelf = self
			break

		case .binary(let a, let b, let c):
			newSelf = .binary(try a.visit(visitor), try b.visit(visitor), try c.visit(visitor))

		case .column(let c):
			newSelf = .column(try c.visit(visitor))

		case .unary(let unary, let ex):
			newSelf = .unary(try unary.visit(visitor), try ex.visit(visitor))
		}

		return try visitor.visit(expression: newSelf)
	}
}

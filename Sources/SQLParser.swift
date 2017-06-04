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
		return name.lowercased()
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

	func sql(dialect: SQLDialect) -> String {
		switch self {
		case .text: return "TEXT"
		case .int: return "INT"
		}
	}
}

struct SQLSchema {
	var columns = OrderedDictionary<SQLColumn, SQLType>()
}

enum SQLStatement {
	case create(table: SQLTable, schema: SQLSchema)
	case delete(from: SQLTable, where: SQLExpression?)
	case drop(table: SQLTable)
	case insert(into: SQLTable, columns: [SQLColumn], values: [[SQLExpression]])
	case select(these: [SQLExpression], from: SQLTable?, where: SQLExpression?, distinct: Bool)
	case update

	var isMutating: Bool {
		switch self {
		case .create, .drop, .delete, .update, .insert(into:_, columns:_, values:_):
			return true

		case .select(_):
			return false
		}
	}

	func sql(dialect: SQLDialect) -> String {
		switch self {
		case .create(table: let table, schema: let schema):
			let def = schema.columns.map { (col, type) -> String in
				return "\(col.sql(dialect:dialect)) \(type.sql(dialect: dialect))"
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

		case .insert(into: let into, columns: let cols, values: let tuples):
			let colSQL = cols.map { $0.sql(dialect: dialect) }.joined(separator: ", ")
			let tupleSQL = tuples.map { tuple in
				let ts = tuple.map { $0.sql(dialect: dialect) }.joined(separator: ",")
				return "(\(ts))"
				}.joined(separator: ", ")

			return "INSERT INTO \(into.sql(dialect: dialect)) (\(colSQL)) VALUES \(tupleSQL);"

		case .update:
			return "UPDATE;"

		case .select(let exprs, from: let table, where: let w, distinct: let d):
			let selectList = exprs.map { $0.sql(dialect: dialect) }.joined(separator: ", ")
			let distinctSQL = d ? " DISTINCT" : ""

			if let t = table {
				let whereSQL: String
				if let w = w {
					whereSQL = " WHERE \(w.sql(dialect: dialect))"
				}
				else {
					whereSQL = ""
				}

				return "SELECT\(distinctSQL) \(selectList) FROM \(t.sql(dialect: dialect))\(whereSQL);"
			}
			else {
				return "SELECT\(distinctSQL) \(selectList);"
			}
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

	func sql(dialect: SQLDialect) -> String {
		switch self {
		case .equals: return "="
		case .notEquals: return "<>"
		case .lessThan: return "<"
		case .greaterThan: return ">"
		case .lessThanOrEqual: return "<="
		case .greaterThanOrEqual: return ">="
		}
	}
}

enum SQLExpression {
	case literalInteger(Int)
	case literalString(String)
	case column(SQLColumn)
	case allColumns
	case null
	indirect case binary(SQLExpression, SQLBinary, SQLExpression)

	func sql(dialect: SQLDialect) -> String {
		switch self {
		case .literalString(let s):
			return dialect.literalString(s)

		case .literalInteger(let i):
			return "\(i)"

		case .column(let c):
			return c.sql(dialect: dialect)

		case .allColumns:
			return "*"

		case .null:
			return "NULL"

		case .binary(let left, let binary, let right):
			return "(\(left.sql(dialect: dialect)) \(binary.sql(dialect: dialect)) \(right.sql(dialect: dialect)))"
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
	case columnDefinition(column: SQLColumn, type: SQLType)
	case binaryOperator(SQLBinary)
}

internal class SQLParser: Parser, CustomDebugStringConvertible {
	private var stack: [SQLFragment] = []

	private func pushLiteralString() {
		// TODO: escaping
		self.stack.append(.expression(.literalString(self.text)))
	}

	var debugDescription: String {
		return "\(self.stack)"
	}

	var root: SQLFragment? {
		return self.stack.last
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

		add_named_rule("lit-column", rule: (firstCharacter ~ (followingCharacter*)/~) => {
			self.stack.append(.columnIdentifier(SQLColumn(name: self.text)))
		})

		add_named_rule("lit-all-columns", rule: Parser.matchLiteral("*") => {
			self.stack.append(.expression(.allColumns))
		})

		add_named_rule("lit-string", rule: Parser.matchLiteral("'") ~ Parser.matchAnyCharacterExcept([Character("'")])* => pushLiteralString ~ Parser.matchLiteral("'"))
		add_named_rule("lit", rule:
			^"lit-int"
			| ^"lit-all-columns"
			| ^"lit-string"
			| ^"lit-null"
			| (^"lit-column" => {
				guard case .columnIdentifier(let c) = self.stack.popLast()! else { fatalError() }
				self.stack.append(.expression(.column(c)))
			  })
			)

		// Expressions
		add_named_rule("ex-sub", rule: Parser.matchLiteral("(") ~~ ^"ex" ~~ Parser.matchLiteral(")"))
		add_named_rule("ex-value", rule: ^"lit" | ^"ex-sub")

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

		add_named_rule("ex-equality", rule: ^"ex-value" ~~ ((^"ex-equality-operator" ~~ ^"ex-value") => {
			guard case .expression(let right) = self.stack.popLast()! else { fatalError() }
			guard case .binaryOperator(let op) = self.stack.popLast()! else { fatalError() }
			guard case .expression(let left) = self.stack.popLast()! else { fatalError() }
			self.stack.append(.expression(.binary(left, op, right)))
		})/~)

		add_named_rule("ex", rule: ^"ex-equality")

		// Types
		add_named_rule("type-text", rule: Parser.matchLiteral("TEXT") => { self.stack.append(.type(SQLType.text)) })
		add_named_rule("type-int", rule: Parser.matchLiteral("INT") => { self.stack.append(.type(SQLType.int)) })
		add_named_rule("type", rule: ^"type-text" | ^"type-int")

		// Column definition
		add_named_rule("column-definition", rule: (^"lit-column" ~~ ^"type") => {
			guard case .type(let t) = self.stack.popLast()! else { fatalError() }
			guard case .columnIdentifier(let c) = self.stack.popLast()! else { fatalError() }
			self.stack.append(.columnDefinition(column: c, type: t))
		})

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
				self.stack.append(.statement(.select(these: [], from: nil, where: nil, distinct: false)))
			}
			~~ ((Parser.matchLiteralInsensitive("DISTINCT") => {
				guard case .statement(let st) = self.stack.popLast()! else { fatalError() }
				guard case .select(these: _, from: _, where: _, distinct: _) = st else { fatalError() }
				self.stack.append(.statement(.select(these: [], from :nil, where: nil, distinct: true)))
			})/~)
			~~ (^"tuple" => {
				guard case .tuple(let exprs) = self.stack.popLast()! else { fatalError() }
				guard case .statement(let st) = self.stack.popLast()! else { fatalError() }
				guard case .select(these: _, from: _, where: _, distinct: let distinct) = st else { fatalError() }

				self.stack.append(.statement(.select(these: exprs, from :nil, where: nil, distinct: distinct)))
			})
			~~ (
					Parser.matchLiteralInsensitive("FROM") ~~ ^"id-table" => {
						guard case .statement(let st) = self.stack.popLast()! else { fatalError() }
						guard case .select(these: let exprs, from: _, where: _, distinct: let distinct) = st else { fatalError() }
						self.stack.append(.statement(.select(these: exprs, from: SQLTable(name: self.text), where: nil, distinct: distinct)))
					}
					~~ (Parser.matchLiteralInsensitive("WHERE") ~~ ^"ex" => {
						guard case .expression(let expression) = self.stack.popLast()! else { fatalError() }
						guard case .statement(let st) = self.stack.popLast()! else { fatalError() }
						guard case .select(these: let exprs, from: let from, where: _, distinct: let distinct) = st else { fatalError() }

						self.stack.append(.statement(.select(these: exprs, from: from, where: expression, distinct: distinct)))
					})/~
				)/~
		)

		add_named_rule("create-ddl-statement", rule: Parser.matchLiteralInsensitive("CREATE TABLE")
			~~ (^"id-table" => {
					self.stack.append(.statement(.create(table: SQLTable(name: self.text), schema: SQLSchema())))
				})
			~~ Parser.matchLiteral("(")
			~~ Parser.matchList(^"column-definition" => {
				if case .columnDefinition(column: let column, type: let type) = self.stack.popLast()!,
					case .statement(let s) = self.stack.popLast()!,
					case .create(table: let t, schema: let oldSchema) = s {
						var newSchema = oldSchema
						newSchema.columns[column] = type
						self.stack.append(.statement(.create(table: t, schema: newSchema)))
				}
				else {
					fatalError("IMPOSSIBRU")
				}
			}, separator: Parser.matchLiteral(","))
			~~ Parser.matchLiteral(")")
		)

		add_named_rule("drop-ddl-statement", rule: Parser.matchLiteralInsensitive("DROP TABLE")
			~~ (^"id-table" => {
				self.stack.append(.statement(.drop(table: SQLTable(name: self.text))))
			})
		)

		add_named_rule("update-dml-statement", rule: Parser.matchLiteralInsensitive("UPDATE"))
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
			Parser.matchLiteralInsensitive("INSERT INTO")
				~~ (^"id-table" => { self.stack.append(.tableIdentifier(SQLTable(name: self.text))) })
				~~ ((Parser.matchLiteral("(") => { self.stack.append(.columnList([])) }) ~~ ^"column-list" ~~ Parser.matchLiteral(")"))
				~~ Parser.matchLiteralInsensitive("VALUES") ~~ ((Parser.matchLiteral("(") => { self.stack.append(.tuple([])) }) ~~ ^"tuple" ~~ Parser.matchLiteral(")"))
			) => {
				if  case .tuple(let rs) = self.stack.popLast()!,
					case .columnList(let cs) = self.stack.popLast()!,
					case .tableIdentifier(let tn) = self.stack.popLast()! {
					self.stack.append(.statement(.insert(into: tn, columns: cs, values: [rs])))
				}
			})

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


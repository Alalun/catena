# SQL as understood by Catena

Catena supports a subset of SQL with the following general remarks:

* Column and table names are case-insensitive, and must start with an alphabetic (a-Z) character, and may subsequently contain numbers and underscores. Column names may be placed between double quotes.
* SQL keywords (such as 'SELECT') are case-insensitive.
* Whitespace is allowed between different tokens in an SQL statement, but not inside (e.g. "123 45" will not parse).
* All statements must end with a semicolon.
* Values can be a string (between 'single quotes'), an integer, blobs (X'hex' syntax) or NULL.
* An expression can be a value, '*' a column name, or a supported operation
* Supported comparison operators are "=", "<>", "<", ">", ">=", "<="
* Supported mathematical operators are "+", "-", "/" and "*". The concatenation operator "||" is also supported.
* Other supported operators are the prefix "-" for negation, "NOT", and "x IS NULL" / "x IS NOT NULL"
* Currently only the types 'TEXT' , 'INT' and 'BLOB' are supported.
* Type semantics follow those of SQLite (for now)

In the future, the Catena parser will be expanded to support more types of statements. Only deterministic queries will
be supported (e.g. no functions that return current date/time or random values).

Any transaction executes in a 'current database'. Some statements can be executed outside of a specific
database context. For these, any database name (e.g. "") is allowed.

## Statements

### Statement types

The following statement types are supported in Catena.

#### CREATE DATABASE

Creates a database and makes the invoker of the statement the owner of the database. If the database
already exists, the transaction is rolled back. Note: the 'current database' for the transaction must be the
database that is about to be created.

#### DROP DATABASE

Removes the indicated database, but only if there are no tables left in the database. Only the owner of the
database can execute this statement.

#### SELECT

#### INSERT

#### UPDATE

#### DELETE

#### CREATE TABLE

#### DROP TABLE

#### DO...END

This syntax can be used to execute multiple statements sequentially: `DO x; y; z END;` (where x, y and
z are each statements). The result of the statement is the result of the *last* statement executed. Sequential
execution stops when any of the statements fails (and the transaction is rolled back completely).

#### GRANT / REVOKE

Grant and revoke statements create privileges in a database to perform certain privileged actions. The
statements look as follows:

````
GRANT permission TO X'userhash';
GRANT permission ON "table" TO X'userhash';
REVOKE permission TO X'userhash';
REVOKE permission ON "table" TO X'userhash';
````

In the above, `permission` is one of the valid permission names (e.g. create, delete, update, drop). When
no table is specified, the grant applies to all tables In the database. A grant can be created and remains
valid for tables that do not exist yet, or are dropped while a grant exists.

#### DESCRIBE

Returns information on the defintion of a table's contents. The `DESCRIBE` statement must be called
following an identifier of an existing table (calling `DESCRIBE` for a table that does not exist will cause an
error). The rows in the returned table are in the order of the columns as they appear on the described table.

The returned table has the following columns:

| column | type | description |
|---------|-------|---------------|
| column | TEXT | The name of the column |
| type | TEXT | The type of the column: TEXT, INT, BLOB |
| in_primary_key | INT | 1 when the column is part of the table's primary key, 0 when it is not |
| not_null | INT | 1 when the column cannot be NULL, 0 otherwise |
| default_value | `type` | The default value for this column, or NULL when it has no default value |

#### SHOW

#### SHOW TABLES

Returns a list of all tables that are accessible (disregarding permissions) as a single table with column `name` containing the
name of each table.

#### SHOW ALL

Currently unimplemented; returns connection settings. The columns are named 'name', 'setting' and 'description'.

#### SHOW DATABASES

Returns a list of databases and their owner public key hashes. This statement can be executed outside
of database context (as well as inside, it does not make a difference).

Optionally, you can specifiy a public key hash for which the owned databases should be returned:

````sql
SHOW DATABASES FOR X'1ac71735e59106b72e0a9d2e4795b5f29077c02ed61a4af46e6e311f88b63e7b';
````

#### SHOW GRANTS

Returns the list of grants in the current database (the columns are `user`, `kind` and `table`).

#### IF ... THEN ... ELSE ... END

A top-level IF statement can be used to control execution flow. The standard IF statement looks as follows:

````
IF ?amount > 0 THEN UPDATE balance SET balance = balance + ?amount WHERE iban = ?iban ELSE FAIL END;
````

You can also add additional `ELSE IF` clauses:

````
IF ?x < 10 THEN INSERT INTO foo(x) VALUES(?x) ELSE IF ?x < 20 THEN INSERT INTO bar(x) VALUES (?x) ELSE FAIL END;
````

The branches of an IF statement can only contain mutating statements (e.g. no SELECT).

When an `ELSE` clause is omitted, `ELSE FAIL` is implied:

````
IF ?x < 10 THEN INSERT INTO foo(x) VALUES(?x) END;
````

The top-level IF-statement is very useful for restricting template grants to certain subsets of parameters.

#### FAIL

Ends execution of the statement and rolls back any change made in the transaction.

### Limits

#### Nesting of subexpressions

There can be no more than *10* nested sub-expressions and/or sub-statements (both count to the same total). The folllowing add one nesting level:
* Sub-statements of an `IF` expression
* Sub-expressions between brackets
* The select statement inside an `EXISTS` expression.

## Expressions

### Variables

Catena exposes several variables in queries:

| Variable | Type | Description |
|----------|-------|---------------|
| $invoker | BLOB (32 bytes) | The SHA-256 hash of the public key of the invoker of the query |
| $blockHeight | INT | The index of the block of which this query's transaction is part |
| $blockSignature | BLOB (32 bytes) | The signature of the block of which this query's transaction is part |
| $previousBlockSignature | BLOB (32 bytes) | The signature of the block before the block of which this query's transaction is part |
| $blockMiner | BLOB (32 bytes) | The SHA-256 hash of the public key of the miner of the block that contains this transaction |
| $blockTimestamp | INT | The UNIX timestamp of the block that contains this transaction |

### Parameters

Catena supports parametrization of queries. This will be used in the future to define stored procedures.

In Catena, a query can contain _bound_ and _unbound_ parameters. An _unbound_ parameter is a placeholder for a literal value.
Queries that contain unbound parameters cannot be executed - they are only used as templates, where parameters are later
substituted with _bound_ parameters or the bound values themselves. A _bound_ parameter is a parameter that has a value
bound to it. A query containing bound parameters can be executed once the bound parameters have been replaced with their
value.

Parameter names follow variable name rules (i.e. should start with an alphanumeric character, may contain numbers and
underscores afterwards). An unbound parameter is written as `?name`. A bound parameter is written as `?name:value` where
`value` is a constant literal (e.g. a string, integer, blob, null or a variable whose value is known before the query executes). Hence
`value` may not be another parameter or a column reference.

### Logical and comparison operators

Catena supports the standard comparison operators (=, <>, <=, >=, >, <) as well as the standard logic operators (AND, OR). Logic operators
result in an integer `1` (true) or `0` (false).

Non-zero values are (cf. SQLite semantics) interpreted as being true. Values that cast to a non-zero integer
are considered true as well (e.g. `SELECT 1 AND '1foo';` returns `1`, whereas `SELECT 1 AND '0foo';` returns `0`,).

### Functions

* LENGTH(str): returns the length of string `str`
* ABS(num): returns the absolute value of number `num`

### Macros

Macros are functions that are executed by the client before a query is submitted to the chain.

* VERSION(): returns information about the current version of the software (this primarily exists for Postgres compatibility and is unlikely to change except for major changes)
* UUID(): generates a new, random UUID string

### Subexpressions

* EXISTS(select): returns '1' when the `select` statement returns at least one row, '0' if it returns no rows. The select query may contain references to the outside query ('correlated' subquery).

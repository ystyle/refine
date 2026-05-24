# PostgreSQL Integration Tests Design

## Problem
Refine ORM lacks integration tests with real PostgreSQL connections. The `Query<T>` builder is hardcoded to `SQLiteDialect()`, making it unusable with PostgreSQL.

## Changes

### 1. `src/query.cj` — Add dialect support to Query\<T\>
- Add `var queryDialect: Option<Dialect> = None` field
- Add `public func dialect(d: Dialect): Query<T>` setter  
- Change `getDialect()` from static to instance method that checks `queryDialect`

### 2. `example/src/setup.cj` — Test helpers
- `getPGSession()` — create Session with PostgreSQL connection
- `createTables(session, dialect)` — DDL for users/posts tables
- `seedData(session)` — INSERT test data
- `cleanupDatabase(session)` — DROP tables

### 3. `example/src/main.cj` — Integration test runner
Test categories:
- Raw SQL CRUD via Session.execute/query
- Query<T> with PostgreSQLDialect: all/one/count/exists/where/orderBy/limit
- Transaction commit/rollback/savepoint
- Live PostgreSQL rendering via Statement + PostgreSQLDialect.render()

Each test prints pass/fail with diagnostic output.

### Entity classes (no macros)
- `User` with id/name/email + `mapUser()` mapper
- `Post` with id/title/content/userId + `mapPost()` mapper
- `Col<User>.id`, `Col<User>.name`, etc. for type-safe column references

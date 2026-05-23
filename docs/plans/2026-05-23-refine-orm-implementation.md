# Refine ORM 实现计划

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 实现 Refine ORM 的全部核心功能（表达式系统、宏、类型映射、连接管理、映射、钩子、迁移）

**Architecture:** 分层实现，从底层向上。Phase 1 运行时类型/构建器 → Phase 2 宏生成 → Phase 3 类型/连接/映射/迁移 → Phase 4 工具链。

**Tech Stack:** 仓颉语言 1.1.0, std.database.sql, stdx.encoding.json.stream, cjc 宏系统

---

## Phase 1：表达式系统与查询构建器

### Task 1.1: Expr / BinOp / UnaryOp 核心枚举

**Files:**
- Create: `src/refine/expr.cj`
- Test: `tests/expr_test.cj`

**Step 1: Write the failing tests**

```cangjie
// tests/expr_test.cj
package tests

import refine.expr.*

main(): Int64 {
    // Column
    let col = Expr.Column("name")
    // match col { case Column(n) => assert(n == "name") }

    // BinOp
    let eq = Expr.BinOp(Expr.Column("id"), BinOp.Eq, Expr.Value(1))
    // match eq { case BinOp(_, Eq, _) => 0 }

    // UnaryOp
    let isnull = Expr.UnaryOp(UnaryOp.IsNull, Expr.Column("name"))

    // 便捷方法
    let a = Expr.Column("a")
    let b = Expr.Column("b")
    let combined = a.and(b).or(Expr.Column("c").not())

    println("Expr tests passed")
    return 0
}
```

**Step 2: Run test to verify it fails**

Run: `cjc tests/expr_test.cj -o /tmp/expr_test && /tmp/expr_test`
Expected: Compile error "undefined symbol 'Expr'"

**Step 3: Write minimal implementation**

```cangjie
// src/refine/expr.cj
package refine

public enum Expr {
    | Column(String)
    | Value(Any)
    | BinOp(Expr, BinOp, Expr)
    | UnaryOp(UnaryOp, Expr)
    | FuncCall(String, Array<Expr>)
    | SubQuery(Statement)
    | Raw(String)
}

public enum BinOp {
    | Eq | Ne | Gt | Ge | Lt | Le
    | And | Or
    | Like | In | NotIn | Between
    | Add | Sub | Mul | Div | Mod
}

public enum UnaryOp {
    | Not | IsNull | IsNotNull
}

extend Expr {
    public func and(other: Expr): Expr { BinOp(this, And, other) }
    public func or(other: Expr): Expr  { BinOp(this, Or, other) }
    public func not(): Expr            { UnaryOp(Not, this) }
}
```

**Step 4: Run test to verify it passes**

Run: `cjc tests/expr_test.cj -o /tmp/expr_test && /tmp/expr_test`
Expected: prints "Expr tests passed"

**Step 5: Commit**

```bash
git add src/refine/expr.cj tests/expr_test.cj
git commit -m "feat: add Expr / BinOp / UnaryOp core types"
```

---

### Task 1.2: Col\<T> 字段描述符

**Files:**
- Create: `src/refine/col.cj`
- Modify: `src/refine/expr.cj`
- Test: `tests/col_test.cj`

**Step 1: Write the failing tests**

```cangjie
// tests/col_test.cj
package tests

import refine.col.*
import refine.expr.*

main(): Int64 {
    let idCol = Col<Int64>("id")
    let titleCol = Col<String>("title")
    let publishedCol = Col<Bool>("published")

    // 操作符返回 Expr
    let expr1 = idCol == 1
    let expr2 = titleCol.like("%refine%")
    let expr3 = publishedCol.isTrue()
    let expr4 = idCol.asc()
    let expr5 = publishedCol == true

    // 列间比较
    let expr6 = idCol == Col<Int64>("other_id")

    // IN
    let expr7 = idCol.in([1, 2, 3])

    println("Col tests passed")
    return 0
}
```

**Step 2: Run test to verify it fails**

Run: `cjc tests/col_test.cj -o /tmp/col_test && /tmp/col_test`
Expected: Compile error "undefined symbol 'Col'"

**Step 3: Write minimal implementation**

```cangjie
// src/refine/col.cj
package refine

public struct Col<T> {
    var name: String

    public operator func ==(rhs: T): Expr  { BinOp(Column(name), Eq, Value(rhs)) }
    public operator func !=(rhs: T): Expr  { BinOp(Column(name), Ne, Value(rhs)) }
    public operator func >(rhs: T): Expr   { BinOp(Column(name), Gt, Value(rhs)) }
    public operator func <(rhs: T): Expr   { BinOp(Column(name), Lt, Value(rhs)) }
    public operator func >=(rhs: T): Expr  { BinOp(Column(name), Ge, Value(rhs)) }
    public operator func <=(rhs: T): Expr  { BinOp(Column(name), Le, Value(rhs)) }

    public operator func ==(rhs: Col<T>): Expr { BinOp(Column(name), Eq, Column(rhs.name)) }
    public operator func !=(rhs: Col<T>): Expr { BinOp(Column(name), Ne, Column(rhs.name)) }

    public func asc(): Expr  { FuncCall("ASC", [Column(name)]) }
    public func desc(): Expr { FuncCall("DESC", [Column(name)]) }

    public func `in`(values: Array<T>): Expr {
        BinOp(Column(name), In, Value(values))
    }
    public func notIn(values: Array<T>): Expr {
        BinOp(Column(name), NotIn, Value(values))
    }
}

extend Col<String> {
    public func like(pattern: String): Expr {
        FuncCall("LIKE", [Column(name), Value(pattern)])
    }
}

extend Col<Bool> {
    public func isTrue(): Expr  { UnaryOp(IsNotNull, Column(name)) }
    public func isFalse(): Expr { BinOp(Column(name), Eq, Value(false)) }
}
```

**Step 4: Run test to verify it passes**

Run: `cjc tests/col_test.cj -o /tmp/col_test && /tmp/col_test`
Expected: prints "Col tests passed"

**Step 5: Commit**

```bash
git add src/refine/col.cj tests/col_test.cj
git commit -m "feat: add Col<T> field descriptor with operator overloading"
```

---

### Task 1.3: Relation 关系描述符

**Files:**
- Create: `src/refine/relation.cj`
- Test: `tests/relation_test.cj`

**Step 1: Write the failing tests**

```cangjie
// tests/relation_test.cj
package tests

import refine.relation.*
import refine.col.*
import refine.expr.*

class User {}
class Tag {}

main(): Int64 {
    // RefTo
    let authorRel = RefTo<User>(
        name: "author",
        fk: Col<Int64>("author_id"),
        fields: [Col<Int64>("id"), Col<String>("name")]
    )

    // RefMany
    let tagsRel = RefMany<Tag>(
        name: "tags",
        via: "post_tags",
        fields: [Col<Int64>("id"), Col<String>("name")]
    )

    // 通过 IRelation 统一访问
    let rel: IRelation = authorRel
    let (kind, _, _, _, _, _) = rel.resolve()

    // fields 覆盖
    let customized = tagsRel.fields([Col<String>("name")])

    println("Relation tests passed")
    return 0
}
```

**Step 2: Run test to verify it fails**

Run: `cjc tests/relation_test.cj -o /tmp/rel_test && /tmp/rel_test`

**Step 3: Write minimal implementation**

```cangjie
// src/refine/relation.cj
package refine

public enum RelationKind {
    | RefTo | RefMany | HasOne | HasMany
}

public interface IRelation {
    func resolve(): (RelationKind, String, String, String, Option<String>, Array<Col<Any>>)
}

public open class Relation<TTarget> {
    var name: String
    var targetTable: String
    var kind: RelationKind
    var foreignKey: String
    var via: Option<String>
    var fields: Array<Col<Any>>
    var condition: Option<Expr>

    public func fields(fs: Array<Col<Any>>): this {
        this.fields = fs
        this
    }
}

public class RefTo<TTarget> <: Relation<TTarget> & IRelation {
    public init(name: String, fk: Col<Any>, fields: Array<Col<Any>>) {
        this.kind = RelationKind.RefTo
        this.foreignKey = fk.name
        this.fields = fields
    }

    public func resolve(): (RelationKind, String, String, String, Option<String>, Array<Col<Any>>) {
        (kind, name, targetTable, foreignKey, via, fields)
    }
}

public class RefMany<TTarget> <: Relation<TTarget> & IRelation {
    public init(name: String, via: String, fields: Array<Col<Any>>) {
        this.kind = RelationKind.RefMany
        this.via = Some(via)
        this.fields = fields
    }

    public func resolve(): (RelationKind, String, String, String, Option<String>, Array<Col<Any>>) {
        (kind, name, targetTable, foreignKey, via, fields)
    }
}
```

**Step 4: Run test to verify it passes**

**Step 5: Commit**

```bash
git add src/refine/relation.cj tests/relation_test.cj
git commit -m "feat: add Relation / RefTo / RefMany descriptors"
```

---

### Task 1.4: Clause 枚举 + Statement 结构体

**Files:**
- Create: `src/refine/clause.cj`
- Create: `src/refine/statement.cj`
- Test: `tests/statement_test.cj`

**Step 1: Write the failing tests**

```cangjie
// tests/statement_test.cj
package tests

import refine.clause.*
import refine.expr.*
import refine.statement.*

main(): Int64 {
    let stmt = Statement()
    stmt.clauses.append(SelectClause([Column("id"), Column("title")]))
    stmt.clauses.append(FromClause("post"))
    stmt.clauses.append(WhereClause([BinOp(Column("id"), Eq, Value(1))]))
    stmt.clauses.append(OrderByClause([FuncCall("DESC", [Column("created_at")])]))
    stmt.clauses.append(LimitClause(10))

    println("Statement tests passed")
    return 0
}
```

**Step 3: Write minimal implementation**

```cangjie
// src/refine/clause.cj
package refine

public enum Clause {
    | SelectClause(Array<Expr>)
    | FromClause(String)
    | WhereClause(Array<Expr>)
    | GroupByClause(Array<Expr>)
    | HavingClause(Array<Expr>)
    | OrderByClause(Array<Expr>)
    | LimitClause(Int64)
    | OffsetClause(Int64)
    | JoinClause(String, String, Expr)
}
```

```cangjie
// src/refine/statement.cj
package refine

public struct Statement {
    var clauses: ArrayList<Clause> = ArrayList<Clause>()
}
```

---

### Task 1.5: Query\<T> 构建器

**Files:**
- Create: `src/refine/query.cj`
- Test: `tests/query_test.cj`

**Step 3: Write minimal implementation**

```cangjie
// src/refine/query.cj
package refine

public class Query<T> {
    private var stmt = Statement()
    private var exec: ExecutionContext = None
    private var relations: Array<IRelation> = []

    public func select(fields: Array<Col<Any>>): Query<T> {
        stmt.clauses.append(SelectClause(fields.map(f => Column(f.name) as Expr)))
        this
    }

    public func where(predicates: Array<Expr>): Query<T> {
        stmt.clauses.append(WhereClause(predicates))
        this
    }

    public func where(predicate: Expr): Query<T> {
        stmt.clauses.append(WhereClause([predicate]))
        this
    }

    public func orderBy(fields: Array<Expr>): Query<T> {
        stmt.clauses.append(OrderByClause(fields))
        this
    }

    public func limit(n: Int64): Query<T> {
        stmt.clauses.append(LimitClause(n))
        this
    }

    public func offset(n: Int64): Query<T> {
        stmt.clauses.append(OffsetClause(n))
        this
    }

    public func groupBy(fields: Array<Col<Any>>): Query<T> {
        stmt.clauses.append(GroupByClause(fields.map(f => Column(f.name) as Expr)))
        this
    }

    public func having(predicates: Array<Expr>): Query<T> {
        stmt.clauses.append(HavingClause(predicates))
        this
    }

    public func include(rel: IRelation): Query<T> {
        relations.append(rel)
        this
    }

    public func include(rel: IRelation, fields: Array<Col<Any>>): Query<T> {
        rel.fields(fields)
        relations.append(rel)
        this
    }

    public func using(exec: ExecutionContext): Query<T> {
        this.exec = exec
        this
    }
}
```

---

### Task 1.6: SQLite 方言渲染

**Files:**
- Create: `src/refine/dialect/sqlite.cj`
- Create: `src/refine/dialect/dialect.cj`
- Test: `tests/dialect_test.cj`

**Step 3: Write minimal implementation**

```cangjie
// src/refine/dialect/dialect.cj
package refine.dialect

public interface Dialect {
    func name(): String
    func render(stmt: Statement): (String, Array<Any>)
    func quote(identifier: String): String
    func placeholder(index: Int64): String
}
```

```cangjie
// src/refine/dialect/sqlite.cj
package refine.dialect

public class SQLiteDialect <: Dialect {
    public func name(): String { "sqlite" }

    public func quote(identifier: String): String {
        "\"${identifier}\""
    }

    public func placeholder(index: Int64): String {
        "?"
    }

    public func render(stmt: Statement): (String, Array<Any>) {
        var sql = ""
        var params = ArrayList<Any>()
        for (clause in stmt.clauses) {
            match (clause) {
                case SelectClause(fields) =>
                    sql += "SELECT " + fields.map(f => renderExpr(f)).join(", ")
                case FromClause(table) =>
                    sql += " FROM " + quote(table)
                case WhereClause(predicates) =>
                    sql += " WHERE " + predicates.map(p => renderExpr(p)).join(" AND ")
                case OrderByClause(fields) =>
                    sql += " ORDER BY " + fields.map(f => renderExpr(f)).join(", ")
                case LimitClause(n) =>
                    sql += " LIMIT " + n.toString()
                case OffsetClause(n) =>
                    sql += " OFFSET " + n.toString()
                case GroupByClause(fields) =>
                    sql += " GROUP BY " + fields.map(f => renderExpr(f)).join(", ")
                case HavingClause(predicates) =>
                    sql += " HAVING " + predicates.map(p => renderExpr(p)).join(" AND ")
                case JoinClause(table, on) =>
                    sql += " LEFT JOIN " + quote(table) + " ON " + renderExpr(on)
            }
        }
        (sql, params.toArray())
    }

    private func renderExpr(expr: Expr): String {
        match (expr) {
            case Column(n) => quote(n)
            case Value(v) => "?"  // 占位符，参数收集在另一个流程
            case BinOp(l, op, r) =>
                "${renderExpr(l)} ${renderOp(op)} ${renderExpr(r)}"
            case UnaryOp(op, e) =>
                "${renderUnaryOp(op)} ${renderExpr(e)}"
            case FuncCall(n, args) =>
                "${n}(${args.map(a => renderExpr(a)).join(", ")})"
            case Raw(s) => s
            case _ => ""
        }
    }
}
```

---

## Phase 2：核心宏框架

### Task 2.1: StorageType + TypeAdapter 基础类型

**Files:**
- Create: `src/refine/storage.cj`
- Test: `tests/storage_test.cj`

**Step 3: Write minimal implementation**

```cangjie
// src/refine/storage.cj
package refine

public enum StorageType {
    | Integer | Float | Bool | String | Text
    | Json | Bytes | Timestamp
}

public interface TypeAdapter<T> {
    func storageType(): StorageType
    func toStored(value: T): Any
    func fromStored(stored: Any): T
}
```

---

### Task 2.2: DB / Session / Tx 连接管理

**Files:**
- Create: `src/refine/db.cj`
- Test: `tests/db_test.cj`

---

### Task 2.3: 结果映射器

**Files:**
- Create: `src/refine/mapper.cj`
- Test: `tests/mapper_test.cj`

---

### Task 2.4: 钩子系统

**Files:**
- Create: `src/refine/hook.cj`
- Test: `tests/hook_test.cj`

---

### Task 2.5: @Refine / @Rel / @Ref 宏

**Files:**
- Create: `src/refine/macro/refine_macro.cj`  (宏定义包)
- Create: `src/refine/macro/rel_macro.cj`
- Create: `src/refine/macro/ref_macro.cj`
- Test: `tests/macro_test/entity.cj`
- Test: `tests/macro_test/main.cj`

---

### Task 2.6: 宏生成 CRUD + hook 调用 + Cols + Relation

**Files:**
- Modify: `src/refine/macro/refine_macro.cj`

---

## Phase 3：类型系统、连接管理与迁移

### Task 3.1: Dialect 接口 + 物理类型映射

**Files:**
- Modify: `src/refine/dialect/dialect.cj`
- Create: `src/refine/dialect/mysql.cj`
- Create: `src/refine/dialect/postgres.cj`

### Task 3.2: dispatchSet 参数绑定

**Files:**
- Create: `src/refine/params.cj`

### Task 3.3: Migrator + Schema 自动迁移

**Files:**
- Create: `src/refine/migrator.cj`
- Create: `src/refine/migrator/sqlite_migrator.cj`

### Task 3.4: Query\<T>.all() / one() / count() / exists() 执行链路打通

**Files:**
- Modify: `src/refine/query.cj`

---

## Phase 4：生态与工具

### Task 4.1: 迁移 CLI 工具

### Task 4.2: 错误处理体系 RefineException

### Task 4.3: SQL 日志 / 调试输出

### Task 4.4: 文档与示例

---

## 项目文件结构（最终）

```
src/
├── main.cj
└── refine/
    ├── expr.cj              # Expr / BinOp / UnaryOp
    ├── col.cj               # Col<T>
    ├── relation.cj          # Relation / RefTo / RefMany / IRelation
    ├── clause.cj            # Clause enum
    ├── statement.cj         # Statement struct
    ├── query.cj             # Query<T> builder
    ├── storage.cj           # StorageType / TypeAdapter
    ├── db.cj                # DB / Session / Tx
    ├── mapper.cj            # Result mapper
    ├── params.cj            # dispatchSet
    ├── hook.cj              # Hook system
    ├── migrator.cj          # Migrator interface
    ├── dialect/
    │   ├── dialect.cj       # Dialect interface
    │   ├── sqlite.cj        # SQLiteDialect
    │   ├── mysql.cj         # MySQLDialect
    │   └── postgres.cj      # PostgreSQLDialect
    └── macro/
        ├── refine_macro.cj  # @Refine
        ├── rel_macro.cj     # @Rel
        └── ref_macro.cj     # @Ref
tests/
├── expr_test.cj
├── col_test.cj
├── relation_test.cj
├── statement_test.cj
├── query_test.cj
├── storage_test.cj
├── db_test.cj
├── mapper_test.cj
├── hook_test.cj
└── macro_test/
    ├── entity.cj
    └── main.cj
```

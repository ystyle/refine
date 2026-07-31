macro package refine.macros

import std.ast.*
import std.collection.ArrayList

struct FieldInfo {
    var name: String
    var typeName: String
    var storageOverride: String
    var isPk: Bool
    var autoInc: Bool
    public init(name: String, typeName: String, storageOverride: String,
                isPk: Bool, autoInc: Bool) {
        this.name = name
        this.typeName = typeName
        this.storageOverride = storageOverride
        this.isPk = isPk
        this.autoInc = autoInc
    }
}

struct RelInfo {
    var fieldName: String
    var kind: String
    var target: String
    var by: String
    var fields: ArrayList<String>
    var via: String
    public init(fieldName: String, kind: String, target: String,
                by: String, fields: ArrayList<String>, via: String) {
        this.fieldName = fieldName
        this.kind = kind
        this.target = target
        this.by = by
        this.fields = fields
        this.via = via
    }
}

func extractFields(cd: ClassDecl): ArrayList<FieldInfo> {
    let list = ArrayList<FieldInfo>()
    for (i in 0..cd.body.decls.size) {
        match (cd.body.decls[i] as VarDecl) {
            case Some(vd) =>
                let typeStr = vd.declType.toTokens().toString()
                let fn = vd.identifier.value
                let isPk = (fn == "id")
                let autoInc = (fn == "id" && typeStr == "Int64")
                let info = FieldInfo(fn, typeStr, "", isPk, autoInc)
                list.add(info)
            case _ => ()
        }
    }
    list
}

func detectRelations(fields: ArrayList<FieldInfo>): ArrayList<RelInfo> {
    let result = ArrayList<RelInfo>()
    for (f in fields) {
        let tn = f.typeName
        if (tn.contains("Option<")) {
            let start = tn.indexOf("Option<").getOrThrow() + 7
            let end = tn.lastIndexOf(">").getOrThrow()
            let targetType = tn[start..end]
            let byCol = f.name + "_id"
            let relFields = ArrayList<String>()
            relFields.add("id")
            result.add(RelInfo(f.name, "ref_to", targetType, byCol, relFields, ""))
        } else if (tn.contains("ArrayList<")) {
            let start = tn.indexOf("ArrayList<").getOrThrow() + 10
            let end = tn.lastIndexOf(">").getOrThrow()
            let targetType = tn[start..end]
            let relFields = ArrayList<String>()
            relFields.add("id")
            result.add(RelInfo(f.name, "ref_many", targetType, "", relFields, f.name))
        } else if (tn.contains("Array<")) {
            let start = tn.indexOf("Array<").getOrThrow() + 6
            let end = tn.lastIndexOf(">").getOrThrow()
            let targetType = tn[start..end]
            let relFields = ArrayList<String>()
            relFields.add("id")
            result.add(RelInfo(f.name, "ref_many", targetType, "", relFields, f.name))
        }
    }
    result
}

func isFieldAnnotated(fieldName: String, refMessages: ArrayList<MacroMessage>, relMessages: ArrayList<MacroMessage>): Bool {
    for (m in refMessages) {
        if (m.getString("fieldName") == fieldName) { return true }
    }
    for (m in relMessages) {
        if (m.getString("fieldName") == fieldName) { return true }
    }
    false
}

func mergeAnnotationRels(rels: ArrayList<RelInfo>, refMessages: ArrayList<MacroMessage>, relMessages: ArrayList<MacroMessage>): ArrayList<RelInfo> {
    let result = ArrayList<RelInfo>()
    for (r in rels) {
        if (!isFieldAnnotated(r.fieldName, refMessages, relMessages)) { result.add(r) }
    }
    for (m in refMessages) {
        let fieldName = m.getString("fieldName")
        let target = m.getString("target")
        let kind = m.getString("kind")
        let relFields = ArrayList<String>()
        if (m.hasItem("fields")) {
            let fs = m.getString("fields")
            for (name in fs.split("|")) { relFields.add(name) }
        } else {
            relFields.add("id")
        }
        if (kind == "ref_many") {
            let via = m.getString("via")
            result.add(RelInfo(fieldName, "ref_many", target, "", relFields, via))
        } else {
            let fk = m.getString("fk")
            result.add(RelInfo(fieldName, "ref_to", target, fk, relFields, ""))
        }
    }
    for (m in relMessages) {
        let fieldName = m.getString("fieldName")
        let kind = m.getString("kind")
        let target = m.getString("target")
        var viaOrBy = ""
        if (m.hasItem("via")) { viaOrBy = m.getString("via") }
        let relFields = ArrayList<String>()
        if (m.hasItem("fields")) {
            let fs = m.getString("fields")
            for (name in fs.split("|")) { relFields.add(name) }
        } else {
            relFields.add("id")
        }
        if (kind == "has_many" || kind == "has_one") {
            result.add(RelInfo(fieldName, kind, target, viaOrBy, relFields, ""))
        }
    }
    result
}

func lowerTableName(name: String): String {
    if (name.size == 0) { return name }
    name[0..1].toAsciiLower() + name[1..]
}

func upperFirstLetter(name: String): String {
    if (name.size == 0) { return name }
    name[0..1].toAsciiUpper() + name[1..]
}

func isRelationField(typeName: String): Bool {
    typeName.contains("Option") || typeName.contains("ArrayList") || typeName.contains("Array")
}

func getPkFields(fields: ArrayList<FieldInfo>): ArrayList<FieldInfo> {
    let result = ArrayList<FieldInfo>()
    for (f in fields) { if (f.isPk) { result.add(f) } }
    result
}

func shouldSkipInInsert(f: FieldInfo): Bool {
    isRelationField(f.typeName) || (f.isPk && f.autoInc)
}

func applyIdAnnotations(fields: ArrayList<FieldInfo>, idMessages: ArrayList<MacroMessage>): ArrayList<FieldInfo> {
    if (idMessages.size == 0) { return fields }
    var result = ArrayList<FieldInfo>()
    for (i in 0..fields.size) {
        var f = fields.get(i).getOrThrow()
        f.isPk = false; f.autoInc = false
        result.add(f)
    }
    for (m in idMessages) {
        let fieldName = m.getString("fieldName")
        var next = ArrayList<FieldInfo>()
        for (i in 0..result.size) {
            let f = result.get(i).getOrThrow()
            if (f.name == fieldName) {
                var updated = f
                updated.isPk = true
                if (m.hasItem("auto") && m.getString("auto") == "true" && f.typeName == "Int64") {
                    updated.autoInc = true
                }
                next.add(updated)
            } else { next.add(f) }
        }
        result = next
    }
    result
}

func buildPkWhereClause(pkFields: ArrayList<FieldInfo>): String {
    var parts = ArrayList<String>()
    for (pk in pkFields) { parts.add(pk.name + " = ?") }
    if (parts.size == 0) { return "WHERE id = ?" }
    " WHERE " + String.join(parts.toArray(), delimiter: " AND ")
}

func typeNameToStorageType(typeName: String): String {
    if (typeName == "Int8" || typeName == "Int16" || typeName == "Int32" || typeName == "Int64" ||
        typeName == "UInt8" || typeName == "UInt16" || typeName == "UInt32" || typeName == "UInt64") {
        "StorageType.Integer"
    } else if (typeName == "Float32" || typeName == "Float64") { "StorageType.Float"
    } else if (typeName == "Bool") { "StorageType.`Bool`"
    } else if (typeName == "String") { "StorageType.String"
    } else if (typeName == "Array<UInt8>") { "StorageType.Bytes"
    } else { "StorageType.Text" }
}

func buildColsStruct(className: String, cd: ClassDecl): Tokens {
    let colsName = Token(TokenKind.IDENTIFIER, className + "Cols")
    var colsFields = Tokens()
    var first = true
    for (i in 0..cd.body.decls.size) {
        match (cd.body.decls[i] as VarDecl) {
            case Some(vd) =>
                if (!first) { colsFields = colsFields + Token(TokenKind.NL) }
                let fn = vd.identifier.value
                colsFields = colsFields + quote(
                    public let $(vd.identifier): Col<$(vd.declType)> = Col<$(vd.declType)>($(Token(TokenKind.STRING_LITERAL, fn)))
                )
                first = false
            case _ => ()
        }
    }
    quote(
        public struct $(colsName) { $(colsFields) init() {} }
    )
}

func genFieldCols(fieldNames: ArrayList<String>): Tokens {
    var tokens = Tokens()
    tokens = tokens + Token(TokenKind.LSQUARE)
    var first = true
    for (name in fieldNames) {
        if (!first) { tokens = tokens + Token(TokenKind.COMMA) }
        let nameLit = Token(TokenKind.STRING_LITERAL, name)
        tokens = tokens + quote(Col<Any>($(nameLit)))
        first = false
    }
    tokens = tokens + Token(TokenKind.RSQUARE)
    tokens
}

func buildRelClass(className: String, rels: ArrayList<RelInfo>): Tokens {
    let relClassName = Token(TokenKind.IDENTIFIER, className + "Rel")
    if (rels.size == 0) { return quote(public class $(relClassName) {}) }
    var body = Tokens()
    var first = true
    for (i in 0..rels.size) {
        let r = rels[i]
        if (!first) { body = body + Token(TokenKind.NL) }
        let fieldIdent = Token(TokenKind.IDENTIFIER, r.fieldName)
        let targetType = Token(TokenKind.IDENTIFIER, r.target)
        let nameLit = Token(TokenKind.STRING_LITERAL, r.fieldName)
        let schemaIdent = Token(TokenKind.IDENTIFIER, r.target + "Schema")
        let targetTableExpr = quote($(schemaIdent)().tableName())
        let mapperIdent = Token(TokenKind.IDENTIFIER, r.fieldName + "Mapper")
        let setterIdent = Token(TokenKind.IDENTIFIER, r.fieldName + "Setter")
        let mapperFuncIdent = Token(TokenKind.IDENTIFIER, r.target + "RowMapper")
        let cnIdent = Token(TokenKind.IDENTIFIER, className)
        body = body + quote(
            public static let $(mapperIdent) = $(mapperFuncIdent)
        )
        body = body + Token(TokenKind.NL)
        if (r.kind == "ref_to" || r.kind == "has_one") {
            body = body + quote(
                public static let $(setterIdent) = { entity: Any, target: Any =>
                    let e = (entity as $(cnIdent)).getOrThrow()
                    e.$(fieldIdent) = target as $(targetType)
                }
            )
        } else {
            body = body + quote(
                public static let $(setterIdent) = { entity: Any, target: Any =>
                    let e = (entity as $(cnIdent)).getOrThrow()
                    e.$(fieldIdent).add((target as $(targetType)).getOrThrow())
                }
            )
        }
        body = body + Token(TokenKind.NL)
        let colNamesFunc = Token(TokenKind.IDENTIFIER, r.target + "ColumnNames")
        let hasCustomFields = r.fields.size > 1 || (r.fields.size == 1 && r.fields[0] != "id")
        var fieldsTok: Tokens
        if (hasCustomFields) {
            fieldsTok = genFieldCols(r.fields)
        } else {
            fieldsTok = Tokens()
            fieldsTok = fieldsTok + colNamesFunc
            fieldsTok = fieldsTok + Token(TokenKind.LPAREN)
            fieldsTok = fieldsTok + Token(TokenKind.RPAREN)
        }
        if (r.kind == "ref_to") {
            let fkLit = Token(TokenKind.STRING_LITERAL, r.by)
            body = body + quote(
                public static let $(fieldIdent) = RefTo<$(targetType)>($(nameLit), Col<Any>($(fkLit)), $(fieldsTok), $(targetTableExpr), $(mapperIdent), $(setterIdent))
            )
        } else if (r.kind == "has_one") {
            let fkLit = Token(TokenKind.STRING_LITERAL, r.by)
            body = body + quote(
                public static let $(fieldIdent) = HasOne<$(targetType)>($(nameLit), $(fkLit), $(fieldsTok), $(targetTableExpr), $(mapperIdent), $(setterIdent))
            )
        } else if (r.kind == "has_many") {
            let fkLit = Token(TokenKind.STRING_LITERAL, r.by)
            body = body + quote(
                public static let $(fieldIdent) = HasMany<$(targetType)>($(nameLit), $(fkLit), $(fieldsTok), $(targetTableExpr), $(mapperIdent), $(setterIdent))
            )
        } else {
            let viaLit = Token(TokenKind.STRING_LITERAL, r.via)
            body = body + quote(
                public static let $(fieldIdent) = RefMany<$(targetType)>($(nameLit), $(viaLit), $(fieldsTok), $(targetTableExpr), $(mapperIdent), $(setterIdent))
            )
        }
        first = false
    }
    quote(public class $(relClassName) { $(body) })
}

func buildSaveMethod(className: String): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    quote(
        public static func save(entity: $(cn)): Unit {
            let scope = Scope<$(cn)>(entity)
            executeHooks($(nameLit), HookKind.BeforeCreate, scope)
            if (scope.aborted) { throw scope.error.getOrThrow() }
            let afterScope = Scope<$(cn)>(entity)
            executeHooks($(nameLit), HookKind.AfterCreate, afterScope)
        }
    )
}

func buildUpdateMethod(className: String): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    quote(
        public static func update(entity: $(cn)): Unit {
            let scope = Scope<$(cn)>(entity)
            executeHooks($(nameLit), HookKind.BeforeUpdate, scope)
            if (scope.aborted) { throw scope.error.getOrThrow() }
            let afterScope = Scope<$(cn)>(entity)
            executeHooks($(nameLit), HookKind.AfterUpdate, afterScope)
        }
    )
}

func buildDeleteMethod(className: String): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    quote(
        public static func delete(entity: $(cn)): Unit {
            let scope = Scope<$(cn)>(entity)
            executeHooks($(nameLit), HookKind.BeforeDelete, scope)
            if (scope.aborted) { throw scope.error.getOrThrow() }
            let afterScope = Scope<$(cn)>(entity)
            executeHooks($(nameLit), HookKind.AfterDelete, afterScope)
        }
    )
}

// --- SQL Generation ---

func buildInsertSQLString(fields: ArrayList<FieldInfo>, tableName: String): String {
    var colNames = ArrayList<String>()
    var placeholders = ArrayList<String>()
    for (f in fields) {
        if (shouldSkipInInsert(f)) { continue }
        colNames.add(f.name)
        placeholders.add("?")
    }
    "INSERT INTO " + tableName + " (" + String.join(colNames.toArray(), delimiter: ", ") +
        ") VALUES (" + String.join(placeholders.toArray(), delimiter: ", ") + ")"
}

func buildEntityArrayTokens(fields: ArrayList<FieldInfo>): Tokens {
    var arr = Tokens()
    arr = arr + Token(TokenKind.LSQUARE)
    var first = true
    for (f in fields) {
        if (shouldSkipInInsert(f)) { continue }
        if (!first) { arr = arr + Token(TokenKind.COMMA) }
        arr = arr + Token(TokenKind.IDENTIFIER, "entity")
        arr = arr + Token(TokenKind.DOT)
        arr = arr + Token(TokenKind.IDENTIFIER, f.name)
        first = false
    }
    arr = arr + Token(TokenKind.RSQUARE)
    arr
}

func buildSelectColumnTokens(fields: ArrayList<FieldInfo>): Tokens {
    var arr = Tokens()
    arr = arr + Token(TokenKind.LSQUARE)
    var first = true
    for (f in fields) {
        if (isRelationField(f.typeName)) { continue }
        if (!first) { arr = arr + Token(TokenKind.COMMA) }
        let colNameLit = Token(TokenKind.STRING_LITERAL, f.name)
        arr = arr + quote(Expr.Column($(colNameLit)))
        first = false
    }
    arr = arr + Token(TokenKind.RSQUARE)
    arr
}

func buildInsertSQLFunc(className: String, fields: ArrayList<FieldInfo>, tableName: String): Tokens {
    let funcName = Token(TokenKind.IDENTIFIER, className + "InsertSQL")
    let cn = Token(TokenKind.IDENTIFIER, className)
    let sqlStr = buildInsertSQLString(fields, tableName)
    let sqlToken = Token(TokenKind.STRING_LITERAL, sqlStr)
    let entityArray = buildEntityArrayTokens(fields)
    quote(
        func $(funcName)(entity: $(cn)): (String, Array<Any>) { ($(sqlToken), $(entityArray)) }
    )
}

func buildClientPkGenTokens(pkFields: ArrayList<FieldInfo>): Tokens {
    var body = Tokens()
    for (pk in pkFields) {
        let fName = Token(TokenKind.IDENTIFIER, pk.name)
        if (pk.typeName == "String") {
            body = body + quote(
                if (entity.$(fName) == "" && this.ref.isSome()) { entity.$(fName) = this.ref.getOrThrow().getIdGenerator().generate() }
            )
        } else if (pk.typeName == "Int64" && !pk.autoInc) {
            body = body + quote(
                if (entity.$(fName) == 0 && this.ref.isSome()) { entity.$(fName) = parseId64(this.ref.getOrThrow().getIdGenerator().generate()) }
            )
        }
    }
    body
}

func buildClientPkGenTokensBatch(pkFields: ArrayList<FieldInfo>): Tokens {
    var body = Tokens()
    for (pk in pkFields) {
        let fName = Token(TokenKind.IDENTIFIER, pk.name)
        if (pk.typeName == "String") {
            body = body + quote(
                if (entities[_bi_].$(fName) == "" && this.ref.isSome()) { entities[_bi_].$(fName) = this.ref.getOrThrow().getIdGenerator().generate() }
            )
        } else if (pk.typeName == "Int64" && !pk.autoInc) {
            body = body + quote(
                if (entities[_bi_].$(fName) == 0 && this.ref.isSome()) { entities[_bi_].$(fName) = parseId64(this.ref.getOrThrow().getIdGenerator().generate()) }
            )
        }
    }
    body
}

func buildAutoPkAssignTokens(pkFields: ArrayList<FieldInfo>): Tokens {
    var body = Tokens()
    for (pk in pkFields) {
        if (pk.autoInc) {
            let fName = Token(TokenKind.IDENTIFIER, pk.name)
            body = body + quote(
                entity.$(fName) = result.lastInsertId;
            )
        }
    }
    body
}

func buildAutoPkReturningTokens(pkFields: ArrayList<FieldInfo>): Tokens {
    var body = Tokens()
    for (pk in pkFields) {
        if (pk.autoInc) {
            let fName = Token(TokenKind.IDENTIFIER, pk.name)
            body = body + quote(
                entity.$(fName) = qr.get<Int64>(0);
            )
        }
    }
    body
}

func buildAutoPkReturningCols(pkFields: ArrayList<FieldInfo>): String {
    var cols = ArrayList<String>()
    for (pk in pkFields) { if (pk.autoInc) { cols.add(pk.name) } }
    String.join(cols.toArray(), delimiter: ", ")
}

func buildTxSaveExtend(className: String, pkFields: ArrayList<FieldInfo>, hasClientPk: Bool, hasAutoPk: Bool): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let insertSQLFuncName = Token(TokenKind.IDENTIFIER, className + "InsertSQL")
    let nameLit = Token(TokenKind.STRING_LITERAL, className)

    if (hasClientPk) {
        let genTokens = buildClientPkGenTokens(pkFields)
        quote(
            extend Tx {
                public func save(entity: $(cn)): Unit {
                    $(genTokens)
                    let scope = Scope<$(cn)>(entity)
                    scope.db = Some(this)
                    if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxBeforeCreate, scope) }
                    if (scope.aborted) { throw scope.error.getOrThrow() }
                    let (sql, params) = $(insertSQLFuncName)(entity)
                    let _ = this.execute(sql, params)
                    let afterScope = Scope<$(cn)>(entity)
                    afterScope.db = Some(this)
                    if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxAfterCreate, afterScope) }
                }
            }
        )
    } else if (hasAutoPk) {
        let assignTokens = buildAutoPkAssignTokens(pkFields)
        let returningTokens = buildAutoPkReturningTokens(pkFields)
        let returningCols = buildAutoPkReturningCols(pkFields)
        let returningColsLit = Token(TokenKind.STRING_LITERAL, returningCols)
        quote(
            extend Tx {
                public func save(entity: $(cn)): Unit {
                    let scope = Scope<$(cn)>(entity)
                    scope.db = Some(this)
                    if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxBeforeCreate, scope) }
                    if (scope.aborted) { throw scope.error.getOrThrow() }
                    let (sql, params) = $(insertSQLFuncName)(entity)
                    if (this.ref.isSome() && this.ref.getOrThrow().getDialect().hasReturningSupport()) {
                        let qr = this.query(sql + " RETURNING " + $(returningColsLit), params)
                        if (qr.next()) { $(returningTokens) }
                        qr.close()
                    } else {
                        let result = this.execute(sql, params)
                        $(assignTokens)
                    }
                    let afterScope = Scope<$(cn)>(entity)
                    afterScope.db = Some(this)
                    if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxAfterCreate, afterScope) }
                }
            }
        )
    } else {
        quote(
            extend Tx {
                public func save(entity: $(cn)): Unit {
                    let scope = Scope<$(cn)>(entity)
                    scope.db = Some(this)
                    if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxBeforeCreate, scope) }
                    if (scope.aborted) { throw scope.error.getOrThrow() }
                    let (sql, params) = $(insertSQLFuncName)(entity)
                    let _ = this.execute(sql, params)
                    let afterScope = Scope<$(cn)>(entity)
                    afterScope.db = Some(this)
                    if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxAfterCreate, afterScope) }
                }
            }
        )
    }
}

func buildBatchInsertSQLFunc(className: String, fields: ArrayList<FieldInfo>, tableName: String): Tokens {
    let funcName = Token(TokenKind.IDENTIFIER, className + "BatchInsertSQL")
    let cn = Token(TokenKind.IDENTIFIER, className)

    var colNames = ArrayList<String>()
    var paramCount = 0
    for (f in fields) {
        if (shouldSkipInInsert(f)) { continue }
        colNames.add(f.name)
        paramCount++
    }
    let colNamesStr = String.join(colNames.toArray(), delimiter: ", ")
    let sqlPrefix = "INSERT INTO " + tableName + " (" + colNamesStr + ") VALUES "
    let sqlPrefixToken = Token(TokenKind.STRING_LITERAL, sqlPrefix)

    var qParts = ArrayList<String>()
    for (_ in 0..paramCount) { qParts.add("?") }
    let placeholderGroup = "(" + String.join(qParts.toArray(), delimiter: ", ") + ")"
    let placeholderGroupToken = Token(TokenKind.STRING_LITERAL, placeholderGroup)

    var addParams = Tokens()
    for (f in fields) {
        if (shouldSkipInInsert(f)) { continue }
        addParams = addParams + quote(
            allParams.add(entities[_i_].$(Token(TokenKind.IDENTIFIER, f.name)));
        )
    }

    quote(
        func $(funcName)(entities: Array<$(cn)>): (String, Array<Any>) {
            var allParams = ArrayList<Any>()
            for (_i_ in 0..entities.size) {
                $(addParams)
            }
            var placeholders = ArrayList<String>()
            for (_j_ in 0..entities.size) {
                placeholders.add($(placeholderGroupToken))
            }
            ($(sqlPrefixToken) + String.join(placeholders.toArray(), delimiter: ", "), allParams.toArray())
        }
    )
}

func buildTxBatchSaveExtend(className: String, pkFields: ArrayList<FieldInfo>, hasClientPk: Bool): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let batchInsertSQLFuncName = Token(TokenKind.IDENTIFIER, className + "BatchInsertSQL")
    let nameLit = Token(TokenKind.STRING_LITERAL, className)

    if (hasClientPk) {
        let genTokens = buildClientPkGenTokensBatch(pkFields)
        quote(
            extend Tx {
                public func batchSave(entities: Array<$(cn)>): Unit {
                    if (entities.size == 0) { return }
                    for (_bi_ in 0..entities.size) {
                        $(genTokens)
                    }
                    for (_bi_ in 0..entities.size) {
                        let e = entities[_bi_]
                        let scope = Scope<$(cn)>(e)
                        scope.db = Some(this)
                        if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxBeforeCreate, scope) }
                        if (scope.aborted) { throw scope.error.getOrThrow() }
                    }
                    let (sql, params) = $(batchInsertSQLFuncName)(entities)
                    let _ = this.execute(sql, params)
                    for (_bi_ in 0..entities.size) {
                        let afterScope = Scope<$(cn)>(entities[_bi_])
                        afterScope.db = Some(this)
                        if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxAfterCreate, afterScope) }
                    }
                }
            }
        )
    } else {
        quote(
            extend Tx {
                public func batchSave(entities: Array<$(cn)>): Unit {
                    if (entities.size == 0) { return }
                    for (_bi_ in 0..entities.size) {
                        let e = entities[_bi_]
                        let scope = Scope<$(cn)>(e)
                        scope.db = Some(this)
                        if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxBeforeCreate, scope) }
                        if (scope.aborted) { throw scope.error.getOrThrow() }
                    }
                    let (sql, params) = $(batchInsertSQLFuncName)(entities)
                    let _ = this.execute(sql, params)
                    for (_bi_ in 0..entities.size) {
                        let afterScope = Scope<$(cn)>(entities[_bi_])
                        afterScope.db = Some(this)
                        if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxAfterCreate, afterScope) }
                    }
                }
            }
        )
    }
}

func buildUpdateSQLString(fields: ArrayList<FieldInfo>, tableName: String, pkFields: ArrayList<FieldInfo>): String {
    var setClauses = ArrayList<String>()
    for (f in fields) {
        if (f.isPk || isRelationField(f.typeName)) { continue }
        setClauses.add(f.name + " = ?")
    }
    "UPDATE " + tableName + " SET " + String.join(setClauses.toArray(), delimiter: ", ") + buildPkWhereClause(pkFields)
}

func buildUpdateEntityArrayTokens(fields: ArrayList<FieldInfo>, pkFields: ArrayList<FieldInfo>): Tokens {
    var arr = Tokens()
    arr = arr + Token(TokenKind.LSQUARE)
    var first = true
    for (f in fields) {
        if (f.isPk || isRelationField(f.typeName)) { continue }
        if (!first) { arr = arr + Token(TokenKind.COMMA) }
        arr = arr + Token(TokenKind.IDENTIFIER, "entity")
        arr = arr + Token(TokenKind.DOT)
        arr = arr + Token(TokenKind.IDENTIFIER, f.name)
        first = false
    }
    for (i in 0..pkFields.size) {
        let pk = pkFields.get(i).getOrThrow()
        if (first) { first = false } else { arr = arr + Token(TokenKind.COMMA) }
        arr = arr + Token(TokenKind.IDENTIFIER, "entity")
        arr = arr + Token(TokenKind.DOT)
        arr = arr + Token(TokenKind.IDENTIFIER, pk.name)
    }
    arr = arr + Token(TokenKind.RSQUARE)
    arr
}

func buildUpdateSQLFunc(className: String, fields: ArrayList<FieldInfo>, tableName: String, pkFields: ArrayList<FieldInfo>): Tokens {
    let funcName = Token(TokenKind.IDENTIFIER, className + "UpdateSQL")
    let cn = Token(TokenKind.IDENTIFIER, className)
    let sqlStr = buildUpdateSQLString(fields, tableName, pkFields)
    let sqlToken = Token(TokenKind.STRING_LITERAL, sqlStr)
    let entityArray = buildUpdateEntityArrayTokens(fields, pkFields)
    quote(
        func $(funcName)(entity: $(cn)): (String, Array<Any>) { ($(sqlToken), $(entityArray)) }
    )
}

func buildTxUpdateExtend(className: String): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let updateSQLFuncName = Token(TokenKind.IDENTIFIER, className + "UpdateSQL")
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    quote(
        extend Tx {
            public func update(entity: $(cn)): Unit {
                let scope = Scope<$(cn)>(entity)
                scope.db = Some(this)
                if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxBeforeUpdate, scope) }
                if (scope.aborted) { throw scope.error.getOrThrow() }
                let (sql, params) = $(updateSQLFuncName)(entity)
                this.execute(sql, params)
                let afterScope = Scope<$(cn)>(entity)
                afterScope.db = Some(this)
                if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxAfterUpdate, afterScope) }
            }
        }
    )
}

func buildDeleteSQLString(tableName: String, pkFields: ArrayList<FieldInfo>): String {
    "DELETE FROM " + tableName + buildPkWhereClause(pkFields)
}

func buildSoftDeleteSQLString(tableName: String, pkFields: ArrayList<FieldInfo>): String {
    "UPDATE " + tableName + " SET deleted_at = ?" + buildPkWhereClause(pkFields)
}

func buildSoftDeleteEntityParamsToken(pkFields: ArrayList<FieldInfo>): Tokens {
    var arr = Tokens()
    arr = arr + Token(TokenKind.LSQUARE)
    arr = arr + Token(TokenKind.IDENTIFIER, "1")
    for (pk in pkFields) {
        arr = arr + Token(TokenKind.COMMA)
        arr = arr + Token(TokenKind.IDENTIFIER, "entity")
        arr = arr + Token(TokenKind.DOT)
        arr = arr + Token(TokenKind.IDENTIFIER, pk.name)
    }
    if (pkFields.size == 0) {
        arr = arr + Token(TokenKind.COMMA)
        arr = arr + Token(TokenKind.IDENTIFIER, "entity")
        arr = arr + Token(TokenKind.DOT)
        arr = arr + Token(TokenKind.IDENTIFIER, "id")
    }
    arr = arr + Token(TokenKind.RSQUARE)
    arr
}

func buildDeleteEntityParamsToken(pkFields: ArrayList<FieldInfo>): Tokens {
    var arr = Tokens()
    arr = arr + Token(TokenKind.LSQUARE)
    var first = true
    for (pk in pkFields) {
        if (!first) { arr = arr + Token(TokenKind.COMMA) }
        arr = arr + Token(TokenKind.IDENTIFIER, "entity")
        arr = arr + Token(TokenKind.DOT)
        arr = arr + Token(TokenKind.IDENTIFIER, pk.name)
        first = false
    }
    if (first) {  // fallback
        arr = arr + Token(TokenKind.IDENTIFIER, "entity")
        arr = arr + Token(TokenKind.DOT)
        arr = arr + Token(TokenKind.IDENTIFIER, "id")
    }
    arr = arr + Token(TokenKind.RSQUARE)
    arr
}

func buildDeleteSQLFunc(className: String, tableName: String, pkFields: ArrayList<FieldInfo>): Tokens {
    let funcName = Token(TokenKind.IDENTIFIER, className + "DeleteSQL")
    let cn = Token(TokenKind.IDENTIFIER, className)
    let sqlToken = Token(TokenKind.STRING_LITERAL, buildDeleteSQLString(tableName, pkFields))
    let entityArray = buildDeleteEntityParamsToken(pkFields)
    quote(
        func $(funcName)(entity: $(cn)): (String, Array<Any>) { ($(sqlToken), $(entityArray)) }
    )
}

func buildSoftDeleteSQLFunc(className: String, tableName: String, pkFields: ArrayList<FieldInfo>): Tokens {
    let funcName = Token(TokenKind.IDENTIFIER, className + "SoftDeleteSQL")
    let cn = Token(TokenKind.IDENTIFIER, className)
    let sqlStr = buildSoftDeleteSQLString(tableName, pkFields)
    let entityArray = buildSoftDeleteEntityParamsToken(pkFields)
    quote(
        func $(funcName)(entity: $(cn)): (String, Array<Any>) { ($(Token(TokenKind.STRING_LITERAL, sqlStr)), $(entityArray)) }
    )
}

func buildTxSoftDeleteExtend(className: String): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let softDeleteSQLFuncName = Token(TokenKind.IDENTIFIER, className + "SoftDeleteSQL")
    let deleteSQLFuncName = Token(TokenKind.IDENTIFIER, className + "DeleteSQL")
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    quote(
        extend Tx {
            public func delete(entity: $(cn)): Unit {
                let scope = Scope<$(cn)>(entity)
                scope.db = Some(this)
                if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxBeforeDelete, scope) }
                if (scope.aborted) { throw scope.error.getOrThrow() }
                let (sql, params) = $(softDeleteSQLFuncName)(entity)
                this.execute(sql, params)
                let afterScope = Scope<$(cn)>(entity)
                afterScope.db = Some(this)
                if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxAfterDelete, afterScope) }
            }

            public func physicalDelete(entity: $(cn)): Unit {
                let scope = Scope<$(cn)>(entity)
                scope.db = Some(this)
                if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxBeforeDelete, scope) }
                if (scope.aborted) { throw scope.error.getOrThrow() }
                let (sql, params) = $(deleteSQLFuncName)(entity)
                this.execute(sql, params)
                let afterScope = Scope<$(cn)>(entity)
                afterScope.db = Some(this)
                if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxAfterDelete, afterScope) }
            }
        }
    )
}

func buildTxDeleteExtend(className: String): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let deleteSQLFuncName = Token(TokenKind.IDENTIFIER, className + "DeleteSQL")
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    quote(
        extend Tx {
            public func delete(entity: $(cn)): Unit {
                let scope = Scope<$(cn)>(entity)
                scope.db = Some(this)
                if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxBeforeDelete, scope) }
                if (scope.aborted) { throw scope.error.getOrThrow() }
                let (sql, params) = $(deleteSQLFuncName)(entity)
                this.execute(sql, params)
                let afterScope = Scope<$(cn)>(entity)
                afterScope.db = Some(this)
                if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxAfterDelete, afterScope) }
            }
        }
    )
}

// --- RowMapper ---

func buildRowMapper(className: String, cd: ClassDecl, rels: ArrayList<RelInfo>): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let funcName = Token(TokenKind.IDENTIFIER, className + "RowMapper")
    var assignments = Tokens()
    assignments = assignments + Token(TokenKind.LET)
    assignments = assignments + Token(TokenKind.IDENTIFIER, "entity")
    assignments = assignments + Token(TokenKind.ASSIGN)
    assignments = assignments + cn
    assignments = assignments + Token(TokenKind.LPAREN)
    assignments = assignments + Token(TokenKind.RPAREN)
    assignments = assignments + Token(TokenKind.NL)
    var first = true
    for (i in 0..cd.body.decls.size) {
        match (cd.body.decls[i] as VarDecl) {
            case Some(vd) =>
                let fieldTypeStr = vd.declType.toTokens().toString()
                if (isRelationField(fieldTypeStr)) { continue }
                if (!first) { assignments = assignments + Token(TokenKind.NL) }
                let fieldNameLit = Token(TokenKind.STRING_LITERAL, vd.identifier.value)
                assignments = assignments + Token(TokenKind.IDENTIFIER, "entity")
                assignments = assignments + Token(TokenKind.DOT)
                assignments = assignments + vd.identifier
                assignments = assignments + Token(TokenKind.ASSIGN)
                assignments = assignments + Token(TokenKind.IDENTIFIER, "result")
                assignments = assignments + Token(TokenKind.DOT)
                assignments = assignments + Token(TokenKind.IDENTIFIER, "get")
                assignments = assignments + Token(TokenKind.LT)
                assignments = assignments + vd.declType.toTokens()
                assignments = assignments + Token(TokenKind.GT)
                assignments = assignments + Token(TokenKind.LPAREN)
                assignments = assignments + Token(TokenKind.IDENTIFIER, "columnMap")
                assignments = assignments + Token(TokenKind.DOT)
                assignments = assignments + Token(TokenKind.IDENTIFIER, "get")
                assignments = assignments + Token(TokenKind.LPAREN)
                assignments = assignments + fieldNameLit
                assignments = assignments + Token(TokenKind.RPAREN)
                assignments = assignments + Token(TokenKind.DOT)
                assignments = assignments + Token(TokenKind.IDENTIFIER, "getOrThrow")
                assignments = assignments + Token(TokenKind.LPAREN)
                assignments = assignments + Token(TokenKind.RPAREN)
                assignments = assignments + Token(TokenKind.RPAREN)
                first = false
            case _ => ()
        }
    }
    for (ri in 0..rels.size) {
        let r = rels[ri]
        if (r.kind == "ref_to" || r.kind == "has_one") {
            let prefixCheck = r.fieldName + ".id"
            let prefixCheckLit = Token(TokenKind.STRING_LITERAL, prefixCheck)
            let tmpName = Token(TokenKind.IDENTIFIER, "tmp")
            let targetType = Token(TokenKind.IDENTIFIER, r.target)
            let fieldIdent = Token(TokenKind.IDENTIFIER, r.fieldName)
            assignments = assignments + Token(TokenKind.NL)
            let check = quote(
                if (columnMap.contains($(prefixCheckLit))) {
                    let $(tmpName) = $(targetType)()
                    $(tmpName).id = result.get<Int64>(columnMap.get($(prefixCheckLit)).getOrThrow())
                    entity.$(fieldIdent) = Some($(tmpName))
                }
            )
            assignments = assignments + check
        }
    }
    assignments = assignments + Token(TokenKind.NL)
    assignments = assignments + Token(TokenKind.IDENTIFIER, "entity")
    quote(
        func $(funcName)(result: QueryResult, columnMap: HashMap<String, Int64>): $(cn) { $(assignments) }
    )
}

func buildKeyExtractor(className: String, pkFields: ArrayList<FieldInfo>): Tokens {
    let funcName = Token(TokenKind.IDENTIFIER, className + "KeyFromResult")
    let pkSize = pkFields.size
    if (pkSize == 0) {
        return quote(
            func $(funcName)(result: QueryResult, columnMap: HashMap<String, Int64>): String {
                result.get<Int64>(columnMap.get("id").getOrThrow()).toString()
            }
        )
    } else if (pkSize == 1) {
        let pk = pkFields.get(0).getOrThrow()
        let pkNameLit = Token(TokenKind.STRING_LITERAL, pk.name)
        if (pk.typeName == "String") {
            return quote(
                func $(funcName)(result: QueryResult, columnMap: HashMap<String, Int64>): String {
                    result.get<String>(columnMap.get($(pkNameLit)).getOrThrow())
                }
            )
        } else {
            return quote(
                func $(funcName)(result: QueryResult, columnMap: HashMap<String, Int64>): String {
                    result.get<Int64>(columnMap.get($(pkNameLit)).getOrThrow()).toString()
                }
            )
        }
    } else {
        var parts = Tokens()
        var first = true
        for (i in 0..pkSize) {
            let pk = pkFields.get(i).getOrThrow()
            let pkNameLit = Token(TokenKind.STRING_LITERAL, pk.name)
            if (first) {
                parts = parts + Token(TokenKind.IDENTIFIER, "var")
                parts = parts + Token(TokenKind.IDENTIFIER, "key")
                parts = parts + Token(TokenKind.ASSIGN)
            } else {
                parts = parts + Token(TokenKind.NL)
                parts = parts + Token(TokenKind.IDENTIFIER, "key")
                parts = parts + Token(TokenKind.ASSIGN)
                parts = parts + Token(TokenKind.IDENTIFIER, "key")
                parts = parts + Token(TokenKind.ADD)
                parts = parts + Token(TokenKind.STRING_LITERAL, ":")
                parts = parts + Token(TokenKind.ADD)
            }
            if (pk.typeName == "String") {
                parts = parts + quote(result.get<String>(columnMap.get($(pkNameLit)).getOrThrow()))
            } else {
                parts = parts + quote(result.get<Int64>(columnMap.get($(pkNameLit)).getOrThrow()).toString())
            }
            first = false
        }
        parts = parts + Token(TokenKind.NL)
        parts = parts + Token(TokenKind.IDENTIFIER, "key")
        quote(
            func $(funcName)(result: QueryResult, columnMap: HashMap<String, Int64>): String { $(parts) }
        )
    }
}

func buildRowMapperMethod(className: String): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let mapperFunc = Token(TokenKind.IDENTIFIER, className + "RowMapper")
    quote(
        public static func rowMapper(): (QueryResult, HashMap<String, Int64>) -> $(cn) {
            $(mapperFunc)
        }
    )
}

func buildFindAllMethod(className: String): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    quote(
        public static func findAll(query: Query<$(cn)>): Array<$(cn)> { query.all() }
    )
}

func buildFindOneMethod(className: String): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    quote(
        public static func findOne(query: Query<$(cn)>): Option<$(cn)> { query.one() }
    )
}

// --- Relation Methods ---

func buildRelationMethods(className: String, rels: ArrayList<RelInfo>, cd: ClassDecl): Unit {
    for (i in 0..rels.size) {
        let r = rels[i]
        let fieldIdent = Token(TokenKind.IDENTIFIER, r.fieldName)
        let targetType = Token(TokenKind.IDENTIFIER, r.target)
        let mapperName = Token(TokenKind.IDENTIFIER, r.target + "RowMapper")
        let prefix = upperFirstLetter(r.fieldName)
        let schemaIdent = Token(TokenKind.IDENTIFIER, r.target + "Schema")
        let tableNameExpr = quote($(schemaIdent)().tableName())
        // SQL 中的表名运行时求值（支持 @Table 覆盖），列名保持原样
        let refToSQL = quote("SELECT * FROM " + $(tableNameExpr) + " WHERE id = ?")
        let hasManyLoadSQL = quote("SELECT * FROM " + $(tableNameExpr) + " WHERE " + $(Token(TokenKind.STRING_LITERAL, r.by)) + " = ?")
        let hasManyClearSQL = quote("DELETE FROM " + $(tableNameExpr) + " WHERE " + $(Token(TokenKind.STRING_LITERAL, r.by)) + " = ?")
        let hasOneLoadSQL = quote("SELECT * FROM " + $(tableNameExpr) + " WHERE " + $(Token(TokenKind.STRING_LITERAL, r.by)) + " = ?")
        let hasOneRemoveSQL = quote("DELETE FROM " + $(tableNameExpr) + " WHERE " + $(Token(TokenKind.STRING_LITERAL, r.by)) + " = ?")

        if (r.kind == "ref_to") {
            let fkField = Token(TokenKind.IDENTIFIER, r.by)
            let loadName = Token(TokenKind.IDENTIFIER, "load" + prefix)
            let getFuncName = Token(TokenKind.IDENTIFIER, "get" + prefix)
            cd.body.decls.add(FuncDecl(quote(
                public func $(loadName)(tx: Tx): Option<$(targetType)> {
                    let fk = this.$(fkField)
                    let result = tx.query($(refToSQL), [fk])
                    let offset = if (tx.ref.isSome()) { tx.ref.getOrThrow().getParamOffset() } else { 0 }
                    let colMap = buildColumnMap(result.columnInfos, offset)
                    if (result.next()) { Some($(mapperName)(result, colMap)) } else { None }
                }
            )))
            cd.body.decls.add(FuncDecl(quote(
                public func $(getFuncName)(): Option<$(targetType)> { this.$(fieldIdent) }
            )))
        } else if (r.kind == "ref_many") {
            let sourceTable = lowerTableName(className)
            let sourceSchemaIdent = Token(TokenKind.IDENTIFIER, className + "Schema")
            let viaLit = Token(TokenKind.STRING_LITERAL, r.via)
            let joinSQL = quote(
                "SELECT " + $(tableNameExpr) + ".* FROM " + $(tableNameExpr) + " JOIN " + $(viaLit) + " ON " + $(tableNameExpr) + ".id = " + $(viaLit) + "." + $(tableNameExpr) + "_id WHERE " + $(viaLit) + "." + $(sourceSchemaIdent)().tableName() + "_id = ?"
            )
            let joinSQLToken = joinSQL
            let loadName = Token(TokenKind.IDENTIFIER, "load" + prefix)
            let getFuncName = Token(TokenKind.IDENTIFIER, "get" + prefix)
            cd.body.decls.add(FuncDecl(quote(
                public func $(loadName)(tx: Tx): ArrayList<$(targetType)> {
                    let result = tx.query($(joinSQLToken), [this.id])
                    let offset = if (tx.ref.isSome()) { tx.ref.getOrThrow().getParamOffset() } else { 0 }
                    let colMap = buildColumnMap(result.columnInfos, offset)
                    var entities = ArrayList<$(targetType)>()
                    while (result.next()) { entities.add($(mapperName)(result, colMap)) }
                    entities
                }
            )))
            cd.body.decls.add(FuncDecl(quote(
                public func $(getFuncName)(): ArrayList<$(targetType)> { this.$(fieldIdent) }
            )))
        } else if (r.kind == "has_many") {
            let cn = Token(TokenKind.IDENTIFIER, className)
            let byField = Token(TokenKind.IDENTIFIER, r.by)
            let addName = Token(TokenKind.IDENTIFIER, "add" + prefix)
            let loadName = Token(TokenKind.IDENTIFIER, "load" + prefix)
            let clearName = Token(TokenKind.IDENTIFIER, "clear" + prefix)
            let removeName = Token(TokenKind.IDENTIFIER, "remove" + prefix)
            cd.body.decls.add(FuncDecl(quote(
                public func $(addName)(tx: Tx, entity: $(targetType)): $(cn) {
                    entity.$(byField) = this.id; tx.save(entity); this
                }
            )))
            cd.body.decls.add(FuncDecl(quote(
                public func $(loadName)(tx: Tx): ArrayList<$(targetType)> {
                    let result = tx.query($(hasManyLoadSQL), [this.id])
                    let offset = if (tx.ref.isSome()) { tx.ref.getOrThrow().getParamOffset() } else { 0 }
                    let colMap = buildColumnMap(result.columnInfos, offset)
                    var entities = ArrayList<$(targetType)>()
                    while (result.next()) { entities.add($(mapperName)(result, colMap)) }
                    entities
                }
            )))
            cd.body.decls.add(FuncDecl(quote(
                public func $(clearName)(tx: Tx): $(cn) {
                    tx.execute($(hasManyClearSQL), [this.id]); this
                }
            )))
            cd.body.decls.add(FuncDecl(quote(
                public func $(removeName)(tx: Tx, entity: $(targetType)): $(cn) {
                    if (entity.id != 0) { tx.delete(entity) }; this
                }
            )))
        } else if (r.kind == "has_one") {
            let cn = Token(TokenKind.IDENTIFIER, className)
            let byField = Token(TokenKind.IDENTIFIER, r.by)
            let setName = Token(TokenKind.IDENTIFIER, "set" + prefix)
            let loadName = Token(TokenKind.IDENTIFIER, "load" + prefix)
            let removeName = Token(TokenKind.IDENTIFIER, "remove" + prefix)
            let loadSQL = quote("SELECT * FROM " + $(tableNameExpr) + " WHERE " + $(Token(TokenKind.STRING_LITERAL, r.by)) + " = ?")
            let removeSQL = quote("DELETE FROM " + $(tableNameExpr) + " WHERE " + $(Token(TokenKind.STRING_LITERAL, r.by)) + " = ?")
            cd.body.decls.add(FuncDecl(quote(
                public func $(setName)(tx: Tx, entity: $(targetType)): $(cn) {
                    entity.$(byField) = this.id; tx.save(entity); this
                }
            )))
            cd.body.decls.add(FuncDecl(quote(
                public func $(loadName)(tx: Tx): Option<$(targetType)> {
                    let result = tx.query($(hasOneLoadSQL), [this.id])
                    let offset = if (tx.ref.isSome()) { tx.ref.getOrThrow().getParamOffset() } else { 0 }
                    let colMap = buildColumnMap(result.columnInfos, offset)
                    if (result.next()) { Some($(mapperName)(result, colMap)) } else { None }
                }
            )))
            cd.body.decls.add(FuncDecl(quote(
                public func $(removeName)(tx: Tx): $(cn) {
                    tx.execute($(hasOneRemoveSQL), [this.id]); this
                }
            )))
        }
    }
}

// --- Schema Generation ---

func mergeFieldOverrides(fields: ArrayList<FieldInfo>, fieldMessages: ArrayList<MacroMessage>): ArrayList<FieldInfo> {
    var result = ArrayList<FieldInfo>()
    for (fi in 0..fields.size) {
        var f = fields[fi]
        for (m in fieldMessages) {
            if (m.getString("fieldName") == f.name) { f.storageOverride = m.getString("storageType") }
        }
        result.add(f)
    }
    result
}

func buildColumnNamesFunc(className: String, cd: ClassDecl): Tokens {
    let funcName = Token(TokenKind.IDENTIFIER, className + "ColumnNames")
    var columns = Tokens()
    columns = columns + Token(TokenKind.LSQUARE)
    var first = true
    for (i in 0..cd.body.decls.size) {
        match (cd.body.decls[i] as VarDecl) {
            case Some(vd) =>
                let fieldTypeStr = vd.declType.toTokens().toString()
                if (isRelationField(fieldTypeStr)) { continue }
                if (!first) { columns = columns + Token(TokenKind.COMMA) }
                let nameLit = Token(TokenKind.STRING_LITERAL, vd.identifier.value)
                columns = columns + quote(Col<Any>($(nameLit)))
                first = false
            case _ => ()
        }
    }
    columns = columns + Token(TokenKind.RSQUARE)
    quote(
        func $(funcName)(): Array<Col<Any>> { $(columns) }
    )
}

func buildSchemaClass(className: String, fields: ArrayList<FieldInfo>, tableName: String): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let schemaName = Token(TokenKind.IDENTIFIER, className + "Schema")
    let tableNameLit = Token(TokenKind.STRING_LITERAL, tableName)
    var colDefs = Tokens()
    var first = true
    for (i in 0..fields.size) {
        let f = fields[i]
        if (isRelationField(f.typeName)) { continue }
        if (!first) { colDefs = colDefs + Token(TokenKind.COMMA) + Token(TokenKind.NL) }
        let nameLit = Token(TokenKind.STRING_LITERAL, f.name)
        let st = if (f.storageOverride != "") { "StorageType." + f.storageOverride } else { typeNameToStorageType(f.typeName) }
        let isPk = if (f.isPk) { "true" } else { "false" }
        let isAutoInc = if (f.autoInc) { "true" } else { "false" }
        colDefs = colDefs + Token(TokenKind.IDENTIFIER, "ColumnDef") + Token(TokenKind.LPAREN) + nameLit + Token(TokenKind.COMMA)
        if (f.storageOverride == "Bool" || (f.storageOverride == "" && f.typeName == "Bool")) {
            colDefs = colDefs + Token(TokenKind.IDENTIFIER, "StorageType") + Token(TokenKind.DOT)
            colDefs = colDefs + Token(TokenKind.IDENTIFIER, "`Bool`")
        } else {
            let stParts = st.split(".")
            colDefs = colDefs + Token(TokenKind.IDENTIFIER, stParts[0]) + Token(TokenKind.DOT)
            colDefs = colDefs + Token(TokenKind.IDENTIFIER, stParts[1])
        }
        colDefs = colDefs + Token(TokenKind.COMMA) + Token(TokenKind.IDENTIFIER, isPk) + Token(TokenKind.COMMA)
        colDefs = colDefs + Token(TokenKind.IDENTIFIER, isAutoInc) + Token(TokenKind.COMMA)
        colDefs = colDefs + Token(TokenKind.IDENTIFIER, "false") + Token(TokenKind.RPAREN)
        first = false
    }
    quote(
        public class $(schemaName) <: TableSchema {
            public func tableName(): String { $(tableNameLit) }
            public func columns(): Array<ColumnDef> { [$(colDefs)] }
            public func indexes(): Array<IndexDef> { [] }
        }
    )
}

func buildJunctionSchema(className: String, rel: RelInfo, tableName: String): Tokens {
    let sourceTable = tableName
    let viaLit = Token(TokenKind.STRING_LITERAL, rel.via)
    let srcColLit = Token(TokenKind.STRING_LITERAL, sourceTable + "_id")
    let tgtColLit = Token(TokenKind.STRING_LITERAL, lowerTableName(rel.target) + "_id")
    let schemaName = Token(TokenKind.IDENTIFIER, className + "_" + upperFirstLetter(rel.fieldName) + "JunctionSchema")
    quote(
        public class $(schemaName) <: TableSchema {
            public func tableName(): String { $(viaLit) }
            public func columns(): Array<ColumnDef> {
                [ColumnDef($(srcColLit), StorageType.Integer, false, false, false),
                 ColumnDef($(tgtColLit), StorageType.Integer, false, false, false)]
            }
            public func indexes(): Array<IndexDef> { [] }
        }
    )
}

func buildSchemasFunc(className: String, junctionRelNames: ArrayList<String>): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let schemaName = Token(TokenKind.IDENTIFIER, className + "Schema")
    if (junctionRelNames.size == 0) {
        quote(
            public static func schemas(): Array<TableSchema> { [$(schemaName)()] }
        )
    } else {
        var arr = Tokens()
        arr = arr + Token(TokenKind.IDENTIFIER, className + "Schema")
        arr = arr + Token(TokenKind.LPAREN) + Token(TokenKind.RPAREN)
        for (relName in junctionRelNames) {
            arr = arr + Token(TokenKind.COMMA)
            let jsName = Token(TokenKind.IDENTIFIER, className + "_" + upperFirstLetter(relName) + "JunctionSchema")
            arr = arr + jsName
            arr = arr + Token(TokenKind.LPAREN) + Token(TokenKind.RPAREN)
        }
        quote(
            public static func schemas(): Array<TableSchema> { [$(arr)] }
        )
    }
}

// --- Main Macro ---

public macro Refine(input: Tokens): Tokens {
    let classDecl = ClassDecl(input)
    let className = classDecl.identifier.value
    let classNameToken = classDecl.identifier

    // Read @Table["xxx"] child annotation for custom table name
    let tableMessages = getChildMessages("Table")
    var tableName = lowerTableName(className)
    if (tableMessages.size > 0) {
        tableName = tableMessages[0].getString("name")
    }

    let fields = extractFields(classDecl)
    let fieldMessages = getChildMessages("Field")
    var mergedFields = mergeFieldOverrides(fields, fieldMessages)
    let idMessages = getChildMessages("Id")
    mergedFields = applyIdAnnotations(mergedFields, idMessages)
    let pkFields = getPkFields(mergedFields)
    var hasClientPk = false
    for (i in 0..pkFields.size) {
        let pk = pkFields.get(i).getOrThrow()
        if (pk.typeName == "String" || (pk.typeName == "Int64" && !pk.autoInc)) { hasClientPk = true; break }
    }
    var hasAutoPk = false
    for (i in 0..pkFields.size) { if (pkFields.get(i).getOrThrow().autoInc) { hasAutoPk = true; break } }
    let rels = detectRelations(fields)

    let refMessages = getChildMessages("Ref")
    let relMessages = getChildMessages("Rel")
    let mergedRels = mergeAnnotationRels(rels, refMessages, relMessages)

    let keyExtractorFunc = buildKeyExtractor(className, pkFields)
    let keyExtractorFuncName = Token(TokenKind.IDENTIFIER, className + "KeyFromResult")

    // Detect soft delete: has deleted_at field AND no @HardDelete annotation
    var hasDeletedAt = false
    for (f in mergedFields) {
        if (f.name == "deleted_at") { hasDeletedAt = true; break }
    }
    let hardDeleteMessages = getChildMessages("HardDelete")
    let isSoftDelete = hasDeletedAt && hardDeleteMessages.size == 0

    let mapperFuncName = Token(TokenKind.IDENTIFIER, className + "RowMapper")
    let selectCols = buildSelectColumnTokens(mergedFields)
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    let queryTokens = if (isSoftDelete) {
        quote(
            public static func query(): Query<$(classNameToken)> {
                let q = Query<$(classNameToken)>()
                q.typeName = $(nameLit)
                q.select($(selectCols))
                q.from($(Token(TokenKind.STRING_LITERAL, tableName)))
                q.filter(Expr.Binary(Expr.Column("deleted_at"), BinOp.Eq, Expr.Value(0)))
                q.setMapper($(mapperFuncName))
                q.setKeyExtractor($(keyExtractorFuncName))
                q
            }
        )
    } else {
        quote(
            public static func query(): Query<$(classNameToken)> {
                let q = Query<$(classNameToken)>()
                q.typeName = $(nameLit)
                q.select($(selectCols))
                q.from($(Token(TokenKind.STRING_LITERAL, tableName)))
                q.setMapper($(mapperFuncName))
                q.setKeyExtractor($(keyExtractorFuncName))
                q
            }
        )
    }
    classDecl.body.decls.add(FuncDecl(queryTokens))

    let colsName = Token(TokenKind.IDENTIFIER, className + "Cols")
    let colTokens = quote(
        public static func col(): $(colsName) { $(colsName)() }
    )
    classDecl.body.decls.add(FuncDecl(colTokens))

    let saveTokens = buildSaveMethod(className)
    classDecl.body.decls.add(FuncDecl(saveTokens))
    let updateTokens = buildUpdateMethod(className)
    classDecl.body.decls.add(FuncDecl(updateTokens))
    let deleteTokens = buildDeleteMethod(className)
    classDecl.body.decls.add(FuncDecl(deleteTokens))

    let findAllTokens = buildFindAllMethod(className)
    classDecl.body.decls.add(FuncDecl(findAllTokens))
    let findOneTokens = buildFindOneMethod(className)
    classDecl.body.decls.add(FuncDecl(findOneTokens))

    let rowMapperTokens = buildRowMapperMethod(className)
    classDecl.body.decls.add(FuncDecl(rowMapperTokens))

    // Generate junction schemas for ref_many relations
    var junctionTokens = Tokens()
    var junctionRelNames = ArrayList<String>()
    for (rel in mergedRels) {
        if (rel.kind == "ref_many") {
            if (junctionRelNames.size > 0) { junctionTokens = junctionTokens + Token(TokenKind.NL) + Token(TokenKind.NL) }
            junctionTokens = junctionTokens + buildJunctionSchema(className, rel, tableName)
            junctionRelNames.add(rel.fieldName)
        }
    }
    let schemasTokens = buildSchemasFunc(className, junctionRelNames)
    classDecl.body.decls.add(FuncDecl(schemasTokens))

    let colsStruct = buildColsStruct(className, classDecl)
    let relClass = buildRelClass(className, mergedRels)
    let insertSQLFunc = buildInsertSQLFunc(className, mergedFields, tableName)
    let txSaveExtend = buildTxSaveExtend(className, pkFields, hasClientPk, hasAutoPk)
    let batchInsertSQLFunc = buildBatchInsertSQLFunc(className, mergedFields, tableName)
    let txBatchSaveExtend = buildTxBatchSaveExtend(className, pkFields, hasClientPk)
    let updateSQLFunc = buildUpdateSQLFunc(className, mergedFields, tableName, pkFields)
    let txUpdateExtend = buildTxUpdateExtend(className)
    let rowMapper = buildRowMapper(className, classDecl, mergedRels)
    buildRelationMethods(className, mergedRels, classDecl)
    let schemaClass = buildSchemaClass(className, mergedFields, tableName)
    let columnNamesFunc = buildColumnNamesFunc(className, classDecl)
    var deleteSQLFunc = buildDeleteSQLFunc(className, tableName, pkFields)
    var txDeleteExtend: Tokens
    if (isSoftDelete) {
        let softDeleteSQLFunc = buildSoftDeleteSQLFunc(className, tableName, pkFields)
        txDeleteExtend = buildTxSoftDeleteExtend(className)
        classDecl.toTokens() + Token(TokenKind.NL) + Token(TokenKind.NL) +
            colsStruct + Token(TokenKind.NL) + Token(TokenKind.NL) + relClass +
            Token(TokenKind.NL) + Token(TokenKind.NL) + insertSQLFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + txSaveExtend +
            Token(TokenKind.NL) + Token(TokenKind.NL) + batchInsertSQLFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + txBatchSaveExtend +
            Token(TokenKind.NL) + Token(TokenKind.NL) + updateSQLFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + txUpdateExtend +
            Token(TokenKind.NL) + Token(TokenKind.NL) + deleteSQLFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + softDeleteSQLFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + txDeleteExtend +
            Token(TokenKind.NL) + Token(TokenKind.NL) + rowMapper +
            Token(TokenKind.NL) + Token(TokenKind.NL) + keyExtractorFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + columnNamesFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + schemaClass +
            junctionTokens
    } else {
        txDeleteExtend = buildTxDeleteExtend(className)
        classDecl.toTokens() + Token(TokenKind.NL) + Token(TokenKind.NL) +
            colsStruct + Token(TokenKind.NL) + Token(TokenKind.NL) + relClass +
            Token(TokenKind.NL) + Token(TokenKind.NL) + insertSQLFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + txSaveExtend +
            Token(TokenKind.NL) + Token(TokenKind.NL) + batchInsertSQLFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + txBatchSaveExtend +
            Token(TokenKind.NL) + Token(TokenKind.NL) + updateSQLFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + txUpdateExtend +
            Token(TokenKind.NL) + Token(TokenKind.NL) + deleteSQLFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + txDeleteExtend +
            Token(TokenKind.NL) + Token(TokenKind.NL) + rowMapper +
            Token(TokenKind.NL) + Token(TokenKind.NL) + keyExtractorFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + columnNamesFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + schemaClass +
            junctionTokens
    }
}

// --- Attribute Macros ---

public macro Ref(attr: Tokens, input: Tokens): Tokens {
    if (attr.size == 0) { return input }
    let decl = parseDecl(input)
    let fieldName = decl.identifier.value
    var target = ""
    var fk = fieldName + "_id"
    var via = ""
    var fieldsStr = ""

    if (attr.size >= 4 && attr[2].kind == TokenKind.IDENTIFIER) {
        // Check if first token is a positional target or a named arg keyword
        if (attr[0].kind == TokenKind.IDENTIFIER && attr[0].value != "target" && attr[0].value != "by" && attr[0].value != "via" && attr[0].value != "fields") {
            target = attr[0].value
        }
        for (i in 0..attr.size) {
            if (attr[i].kind == TokenKind.IDENTIFIER && attr[i].value == "target" && i + 2 < attr.size) { target = attr[i + 2].value }
            if (attr[i].kind == TokenKind.IDENTIFIER && attr[i].value == "by" && i + 2 < attr.size) { fk = attr[i + 2].value }
            if (attr[i].kind == TokenKind.IDENTIFIER && attr[i].value == "via" && i + 2 < attr.size) { via = attr[i + 2].value }
            if (attr[i].kind == TokenKind.IDENTIFIER && attr[i].value == "fields" && i + 2 < attr.size) {
                var fieldsValues = ArrayList<String>()
                var j = i + 2
                if (j < attr.size && attr[j].kind == TokenKind.LSQUARE) {
                    j++
                    while (j < attr.size && attr[j].kind != TokenKind.RSQUARE) {
                        if (attr[j].kind == TokenKind.STRING_LITERAL) {
                            fieldsValues.add(attr[j].value)
                        }
                        j++
                    }
                }
                var firstField = true
                for (fv in fieldsValues) {
                    if (firstField) { fieldsStr = fv; firstField = false }
                    else { fieldsStr = fieldsStr + "|" + fv }
                }
            }
        }
    } else {
        var parsingTarget = true
        for (t in attr) {
            if (t.kind == TokenKind.IDENTIFIER) {
                if (t.value == "via") { via = t.value }
                else if (parsingTarget) { target = t.value; parsingTarget = false }
                else if (via == "") { fk = t.value }
            }
        }
    }
    if (target != "") {
        setItem("fieldName", fieldName)
        if (via != "") {
            setItem("kind", "ref_many")
            setItem("target", target); setItem("via", via)
        } else {
            setItem("kind", "ref_to")
            setItem("target", target); setItem("fk", fk)
        }
        if (fieldsStr != "") { setItem("fields", fieldsStr) }
    }
    input
}

public macro Rel(attr: Tokens, input: Tokens): Tokens {
    if (attr.size == 0) { return input }
    let decl = parseDecl(input)
    let fieldName = decl.identifier.value
    var target = ""; var viaOrBy = ""; var fieldsStr = ""

    if (attr.size >= 4 && attr[2].kind == TokenKind.IDENTIFIER) {
        if (attr[0].kind == TokenKind.IDENTIFIER && (attr[0].value == "has_one" || attr[0].value == "has_many")) {
            // Legacy format: @Rel[has_many, Target, fk]
            for (t in attr) {
                if (t.kind == TokenKind.IDENTIFIER) {
                    if (t.value != "has_one" && t.value != "has_many") {
                        if (target == "") { target = t.value }
                        else if (viaOrBy == "") { viaOrBy = t.value }
                    }
                }
            }
        } else if (attr[0].kind == TokenKind.IDENTIFIER && attr[0].value != "target" && attr[0].value != "by" && attr[0].value != "fields") {
            target = attr[0].value
        }
        for (i in 0..attr.size) {
            if (attr[i].kind == TokenKind.IDENTIFIER && attr[i].value == "target" && i + 2 < attr.size) { target = attr[i + 2].value }
            if (attr[i].kind == TokenKind.IDENTIFIER && attr[i].value == "by" && i + 2 < attr.size) { viaOrBy = attr[i + 2].value }
            if (attr[i].kind == TokenKind.IDENTIFIER && attr[i].value == "fields" && i + 2 < attr.size) {
                var fieldsValues = ArrayList<String>()
                var j = i + 2
                if (j < attr.size && attr[j].kind == TokenKind.LSQUARE) {
                    j++
                    while (j < attr.size && attr[j].kind != TokenKind.RSQUARE) {
                        if (attr[j].kind == TokenKind.STRING_LITERAL) {
                            fieldsValues.add(attr[j].value)
                        }
                        j++
                    }
                }
                var firstField = true
                for (fv in fieldsValues) {
                    if (firstField) { fieldsStr = fv; firstField = false }
                    else { fieldsStr = fieldsStr + "|" + fv }
                }
            }
        }
    } else {
        var index = 0
        for (t in attr) {
            if (t.kind == TokenKind.IDENTIFIER) {
                if (t.value == "has_one" || t.value == "has_many") { continue }
                match (index) { case 0 => target = t.value; case 1 => viaOrBy = t.value; case _ => () }
                index++
            }
        }
    }
    if (target != "") {
        // Auto-detect kind from field type
        let inputStr = input.toString()
        let kind = if (inputStr.contains("ArrayList") || inputStr.contains("Array")) { "has_many" } else { "has_one" }
        setItem("fieldName", fieldName); setItem("kind", kind); setItem("target", target)
        if (viaOrBy != "") { setItem("via", viaOrBy) }
        if (fieldsStr != "") { setItem("fields", fieldsStr) }
    }
    input
}

public macro Field(attr: Tokens, input: Tokens): Tokens {
    if (attr.size == 0) { return input }
    let decl = parseDecl(input)
    let fieldName = decl.identifier.value
    var storageType = "Text"
    for (i in 0..attr.size) {
        if (attr[i].kind == TokenKind.IDENTIFIER) { storageType = attr[i].value; break }
    }
    setItem("fieldName", fieldName); setItem("storageType", storageType)
    input
}

public macro Id(attr: Tokens, input: Tokens): Tokens {
    let decl = parseDecl(input)
    setItem("fieldName", decl.identifier.value)
    if (attr.size >= 3) {
        setItem("auto", attr[2].value)
    }
    input
}

public macro Table(attr: Tokens, input: Tokens): Tokens {
    if (attr.size == 0) { return input }
    for (i in 0..attr.size) {
        if (attr[i].kind == TokenKind.STRING_LITERAL) { setItem("name", attr[i].value); return input }
    }
    input
}

// Marker annotation: entity with this annotation uses physical delete instead of soft delete
public macro HardDelete(input: Tokens): Tokens { input }

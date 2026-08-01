macro package refine.macros

import std.ast.*
import std.collection.ArrayList

struct FieldInfo {
    var name: String
    var typeName: String
    var storageOverride: String
    var isPk: Bool
    var autoInc: Bool
    var isVersion: Bool
    public init(name: String, typeName: String, storageOverride: String,
                isPk: Bool, autoInc: Bool, isVersion: Bool) {
        this.name = name
        this.typeName = typeName
        this.storageOverride = storageOverride
        this.isPk = isPk
        this.autoInc = autoInc
        this.isVersion = isVersion
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
                let info = FieldInfo(fn, typeStr, "", isPk, autoInc, false)
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

func applyAuditVersion(fields: ArrayList<FieldInfo>, versionMessages: ArrayList<MacroMessage>): ArrayList<FieldInfo> {
    var result = ArrayList<FieldInfo>()
    var versionCount = 0
    for (f in fields) {
        var updated = f
        for (m in versionMessages) {
            if (m.getString("fieldName") == f.name) {
                if (f.typeName != "Int64") { throw Exception("@Version field must be Int64: " + f.name) }
                updated.isVersion = true
                versionCount++
            }
        }
        result.add(updated)
    }
    if (versionCount > 1) { throw Exception("entity can only have one @Version field") }
    result
}

func findAuditFields(fields: ArrayList<FieldInfo>): (Bool, Bool) {
    var hasCreatedAt = false
    var hasUpdatedAt = false
    for (f in fields) {
        if (f.name == "created_at" && f.typeName == "DateTime") { hasCreatedAt = true }
        if (f.name == "updated_at" && f.typeName == "DateTime") { hasUpdatedAt = true }
    }
    (hasCreatedAt, hasUpdatedAt)
}

func findVersionField(fields: ArrayList<FieldInfo>): String {
    for (f in fields) { if (f.isVersion) { return f.name } }
    ""
}

func buildAuditCreateTokens(fields: ArrayList<FieldInfo>, target: String): Tokens {
    let (hasCreatedAt, hasUpdatedAt) = findAuditFields(fields)
    let targetTok = Token(TokenKind.IDENTIFIER, target)
    var body = Tokens()
    if (hasCreatedAt) { body = body + quote($(targetTok).created_at = DateTime.now();) }
    if (hasUpdatedAt) {
        body = body + Token(TokenKind.NL)
        body = body + quote($(targetTok).updated_at = DateTime.now();)
    }
    body
}

func buildAuditUpdateTokens(fields: ArrayList<FieldInfo>, target: String): Tokens {
    let (_, hasUpdatedAt) = findAuditFields(fields)
    if (hasUpdatedAt) {
        let targetTok = Token(TokenKind.IDENTIFIER, target)
        quote($(targetTok).updated_at = DateTime.now();)
    } else { Tokens() }
}

func buildVersionInitTokens(fields: ArrayList<FieldInfo>, target: String): Tokens {
    let vname = findVersionField(fields)
    if (vname == "") { return Tokens() }
    let ident = Token(TokenKind.IDENTIFIER, vname)
    let targetTok = Token(TokenKind.IDENTIFIER, target)
    quote(
        if ($(targetTok).$(ident) == 0) { $(targetTok).$(ident) = 1 }
    )
}

func buildPkValueExprTokens(pkFields: ArrayList<FieldInfo>): Tokens {
    if (pkFields.size == 0) {
        Tokens() + Token(TokenKind.IDENTIFIER, "entity") + Token(TokenKind.DOT) + Token(TokenKind.IDENTIFIER, "id")
    } else if (pkFields.size == 1) {
        let pk = pkFields.get(0).getOrThrow()
        Tokens() + Token(TokenKind.IDENTIFIER, "entity") + Token(TokenKind.DOT) + Token(TokenKind.IDENTIFIER, pk.name)
    } else {
        var t = Tokens()
        var first = true
        for (pk in pkFields) {
            if (!first) {
                t = t + Token(TokenKind.ADD)
                t = t + Token(TokenKind.STRING_LITERAL, ":")
                t = t + Token(TokenKind.ADD)
            }
            t = t + Token(TokenKind.IDENTIFIER, "entity")
            t = t + Token(TokenKind.DOT)
            t = t + Token(TokenKind.IDENTIFIER, pk.name)
            t = t + Token(TokenKind.DOT)
            t = t + Token(TokenKind.IDENTIFIER, "toString")
            t = t + Token(TokenKind.LPAREN)
            t = t + Token(TokenKind.RPAREN)
            first = false
        }
        t
    }
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
    } else if (typeName == "DateTime") { "StorageType.Timestamp"
    } else { "StorageType.Text" }
}

func buildColsStruct(className: String, cd: ClassDecl, internalNames: ArrayList<String>): Tokens {
    let colsName = Token(TokenKind.IDENTIFIER, className + "Cols")
    var colsFields = Tokens()
    var first = true
    for (i in 0..cd.body.decls.size) {
        match (cd.body.decls[i] as VarDecl) {
            case Some(vd) =>
                let fn = vd.identifier.value
                if (isGeneratedInternalField(fn, internalNames)) { continue }
                if (!first) { colsFields = colsFields + Token(TokenKind.NL) }
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
            let backingIdent = Token(TokenKind.IDENTIFIER, "_" + r.fieldName)
            body = body + quote(
                public static let $(setterIdent) = { entity: Any, target: Any =>
                    let e = (entity as $(cnIdent)).getOrThrow()
                    e.$(backingIdent) = target as $(targetType)
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

func buildTxSaveExtend(className: String, pkFields: ArrayList<FieldInfo>, hasClientPk: Bool, hasAutoPk: Bool, fields: ArrayList<FieldInfo>): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let insertSQLFuncName = Token(TokenKind.IDENTIFIER, className + "InsertSQL")
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    let auditCreate = buildAuditCreateTokens(fields, "entity")
    let versionInit = buildVersionInitTokens(fields, "entity")
    let preTokens = auditCreate + Token(TokenKind.NL) + versionInit
    let cascadePre = quote(
        if (visitedContains(visited, entity)) { return }
        entity.cascadePreSave(this, visited)
    )
    let cascadePost = quote(entity.cascadePostSave(this, visited))

    if (hasClientPk) {
        let genTokens = buildClientPkGenTokens(pkFields)
        quote(
            extend Tx {
                public func save(entity: $(cn)): Unit {
                    this.saveCascade(entity, ArrayList<Object>())
                }
                public func saveCascade(entity: $(cn), visited: ArrayList<Object>): Unit {
                    $(cascadePre)
                    $(preTokens)
                    $(genTokens)
                    let scope = Scope<$(cn)>(entity)
                    scope.db = Some(this)
                    if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxBeforeCreate, scope) }
                    if (scope.aborted) { throw scope.error.getOrThrow() }
                    let (sql, params) = $(insertSQLFuncName)(entity)
                    let _ = this.execute(sql, params)
                    $(cascadePost)
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
                    this.saveCascade(entity, ArrayList<Object>())
                }
                public func saveCascade(entity: $(cn), visited: ArrayList<Object>): Unit {
                    $(cascadePre)
                    $(preTokens)
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
                    $(cascadePost)
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
                    this.saveCascade(entity, ArrayList<Object>())
                }
                public func saveCascade(entity: $(cn), visited: ArrayList<Object>): Unit {
                    $(cascadePre)
                    $(preTokens)
                    let scope = Scope<$(cn)>(entity)
                    scope.db = Some(this)
                    if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxBeforeCreate, scope) }
                    if (scope.aborted) { throw scope.error.getOrThrow() }
                    let (sql, params) = $(insertSQLFuncName)(entity)
                    let _ = this.execute(sql, params)
                    $(cascadePost)
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

func buildTxUpsertExtend(className: String, fields: ArrayList<FieldInfo>, tableName: String, pkFields: ArrayList<FieldInfo>): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    let tableNameLit = Token(TokenKind.STRING_LITERAL, tableName)
    let genTokens = buildClientPkGenTokens(pkFields)
    let auditCreate = buildAuditCreateTokens(fields, "entity")
    let versionInit = buildVersionInitTokens(fields, "entity")
    let preTokens = auditCreate + Token(TokenKind.NL) + versionInit

    // 列名：所有非关系字段（含主键）
    var colNames = ArrayList<String>()
    for (f in fields) {
        if (isRelationField(f.typeName)) { continue }
        colNames.add(f.name)
    }
    var colsArr = Tokens()
    colsArr = colsArr + Token(TokenKind.LSQUARE)
    var first = true
    for (c in colNames) {
        if (!first) { colsArr = colsArr + Token(TokenKind.COMMA) }
        colsArr = colsArr + Token(TokenKind.STRING_LITERAL, c)
        first = false
    }
    colsArr = colsArr + Token(TokenKind.RSQUARE)

    // 冲突列：主键
    var pkNames = ArrayList<String>()
    for (pk in pkFields) { pkNames.add(pk.name) }
    var pksArr = Tokens()
    pksArr = pksArr + Token(TokenKind.LSQUARE)
    first = true
    for (p in pkNames) {
        if (!first) { pksArr = pksArr + Token(TokenKind.COMMA) }
        pksArr = pksArr + Token(TokenKind.STRING_LITERAL, p)
        first = false
    }
    pksArr = pksArr + Token(TokenKind.RSQUARE)

    // 审计字段：created_at（仅插入，冲突时不覆盖）与 updated_at（冲突时刷新）
    let (hasCreatedAt, hasUpdatedAt) = findAuditFields(fields)
    var auditCreateArr = Tokens()
    auditCreateArr = auditCreateArr + Token(TokenKind.LSQUARE)
    if (hasCreatedAt) { auditCreateArr = auditCreateArr + Token(TokenKind.STRING_LITERAL, "created_at") }
    auditCreateArr = auditCreateArr + Token(TokenKind.RSQUARE)

    var auditUpdateArr = Tokens()
    auditUpdateArr = auditUpdateArr + Token(TokenKind.LSQUARE)
    if (hasUpdatedAt) { auditUpdateArr = auditUpdateArr + Token(TokenKind.STRING_LITERAL, "updated_at") }
    auditUpdateArr = auditUpdateArr + Token(TokenKind.RSQUARE)

    let versionName = findVersionField(fields)
    let versionLit = Token(TokenKind.STRING_LITERAL, versionName)

    // 参数：params.add(entity.field)
    var paramsTok = Tokens()
    for (f in fields) {
        if (isRelationField(f.typeName)) { continue }
        let fName = Token(TokenKind.IDENTIFIER, f.name)
        paramsTok = paramsTok + quote(
            params.add(entity.$(fName));
        )
    }
    // MySQL 的审计更新列需要额外参数（updated_at = ?）
    var mysqlExtraParams = Tokens()
    if (hasUpdatedAt) {
        mysqlExtraParams = mysqlExtraParams + quote(
            if (d.name() == "mysql") { params.add(entity.updated_at); }
        )
    }

    quote(
        extend Tx {
            public func upsert(entity: $(cn)): Unit {
                $(genTokens)
                $(preTokens)
                let scope = Scope<$(cn)>(entity)
                scope.db = Some(this)
                if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxBeforeCreate, scope) }
                if (scope.aborted) { throw scope.error.getOrThrow() }
                let d = this.ref.getOrThrow().getDialect()
                if (!d.hasUpsertSupport()) { throw Exception("upsert not supported by dialect: " + d.name()) }
                let sql = d.upsertSQL($(tableNameLit), $(colsArr), $(pksArr), $(auditCreateArr), $(auditUpdateArr), $(versionLit))
                var params = ArrayList<Any>()
                $(paramsTok)
                $(mysqlExtraParams)
                let _ = this.execute(sql, params.toArray())
                let afterScope = Scope<$(cn)>(entity)
                afterScope.db = Some(this)
                if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxAfterCreate, afterScope) }
            }
        }
    )
}

func pgCastTypeOf(typeName: String): String {
    match (typeName) {
        case "Int8" | "Int16" | "Int32" | "Int64" | "UInt8" | "UInt16" | "UInt32" | "UInt64" => "BIGINT"
        case "Float32" | "Float64" => "DOUBLE PRECISION"
        case "Bool" => "BOOLEAN"
        case "String" => "TEXT"
        case "Array<UInt8>" => "BYTEA"
        case "DateTime" => "TIMESTAMP"
        case _ => "TEXT"
    }
}

func genPkValueParamsTokens(pkFields: ArrayList<FieldInfo>, target: String): Tokens {
    var body = Tokens()
    for (pk in pkFields) {
        body = body + quote(
            allParams.add($(Token(TokenKind.IDENTIFIER, target)).$(Token(TokenKind.IDENTIFIER, pk.name)));
        )
    }
    body
}

func buildBatchUpdateSQLFunc(className: String, fields: ArrayList<FieldInfo>, tableName: String, pkFields: ArrayList<FieldInfo>): Tokens {
    let funcName = Token(TokenKind.IDENTIFIER, className + "BatchUpdateSQL")
    let cn = Token(TokenKind.IDENTIFIER, className)
    let tableNameLit = Token(TokenKind.STRING_LITERAL, tableName)
    let versionName = findVersionField(fields)
    let (_, hasUpdatedAt) = findAuditFields(fields)

    // SET 列：非主键、非关系、非 version、非审计 updated_at 字段（version/updated_at 单独生成 CASE 子句）
    var setCols = ArrayList<String>()
    var colCastTypes = ArrayList<String>()
    for (f in fields) {
        if (f.isPk || isRelationField(f.typeName) || f.isVersion) { continue }
        if (f.name == "updated_at" && f.typeName == "DateTime") { continue }
        setCols.add(f.name)
        colCastTypes.add(pgCastTypeOf(f.typeName))
    }
    var pkNames = ArrayList<String>()
    for (pk in pkFields) { pkNames.add(pk.name) }
    let singlePk = (pkNames.size == 1)
    // CASE 开头的 pk 表达式（编译期）：单 pk -> "CASE pk"；复合 -> "CASE WHEN pk1 = ? AND pk2 = ?"
    var pkCondParts = ArrayList<String>()
    var pkInParts = ArrayList<String>()
    for (n in pkNames) { pkCondParts.add(n + " = ?"); pkInParts.add("?") }
    let pkCond = String.join(pkCondParts.toArray(), delimiter: " AND ")
    let pkIn = String.join(pkInParts.toArray(), delimiter: ", ")
    let caseHead = if (singlePk) { "CASE " + pkNames[0] } else { "CASE" }
    // WHEN 重复子句（运行时按实体数重复）
    let whenClause = if (singlePk) { "WHEN ? THEN ?" } else { "WHEN " + pkCond + " THEN ?" }
    // WHERE IN 的每实体占位：单 pk -> "?"；复合 -> "(?, ?)"
    let inItem = if (singlePk) { "?" } else { "(" + pkIn + ")" }
    let whereHead = if (singlePk) { " WHERE " + pkNames[0] + " IN (" } else { " WHERE (" + String.join(pkNames.toArray(), delimiter: ", ") + ") IN (" }

    // 列名数组字面量（运行时遍历拼 SET 子句）
    var colArr = Tokens()
    colArr = colArr + Token(TokenKind.LSQUARE)
    var first = true
    for (c in setCols) {
        if (!first) { colArr = colArr + Token(TokenKind.COMMA) }
        colArr = colArr + Token(TokenKind.STRING_LITERAL, c)
        first = false
    }
    colArr = colArr + Token(TokenKind.RSQUARE)

    var castArr = Tokens()
    castArr = castArr + Token(TokenKind.LSQUARE)
    first = true
    for (ct in colCastTypes) {
        if (!first) { castArr = castArr + Token(TokenKind.COMMA) }
        castArr = castArr + Token(TokenKind.STRING_LITERAL, ct)
        first = false
    }
    castArr = castArr + Token(TokenKind.RSQUARE)

    // 参数收集：常规列每实体 (pk 值..., 新值)，然后 version 每实体 (pk..., version+1)，
    // 然后 updated_at 每实体 (pk..., updated_at)，最后 IN 列表 (pk 值...)
    var addParams = Tokens()
    for (c in setCols) {
        let colIdent = Token(TokenKind.IDENTIFIER, c)
        addParams = addParams + quote(
            for (_bi_ in 0..entities.size) {
                $(genPkValueParamsTokens(pkFields, "entities[_bi_]"))
                allParams.add(entities[_bi_].$(colIdent));
            }
        )
    }
    if (versionName != "") {
        let vIdent = Token(TokenKind.IDENTIFIER, versionName)
        addParams = addParams + quote(
            for (_bi_ in 0..entities.size) {
                $(genPkValueParamsTokens(pkFields, "entities[_bi_]"))
                allParams.add(entities[_bi_].$(vIdent) + 1);
            }
        )
    }
    if (hasUpdatedAt) {
        addParams = addParams + quote(
            for (_bi_ in 0..entities.size) {
                $(genPkValueParamsTokens(pkFields, "entities[_bi_]"))
                allParams.add(entities[_bi_].updated_at);
            }
        )
    }
    addParams = addParams + quote(
        for (_bi_ in 0..entities.size) {
            $(genPkValueParamsTokens(pkFields, "entities[_bi_]"))
        }
    )

    let caseHeadLit = Token(TokenKind.STRING_LITERAL, caseHead)
    let whenClauseLit = Token(TokenKind.STRING_LITERAL, whenClause)
    let inItemLit = Token(TokenKind.STRING_LITERAL, inItem)
    let whereHeadLit = Token(TokenKind.STRING_LITERAL, whereHead)
    let castArrTok = castArr

    // 额外的 SET 子句（version / updated_at 独立 CASE）
    var extraSetParts = Tokens()
    if (versionName != "") {
        let vNameLit = Token(TokenKind.STRING_LITERAL, versionName)
        let vCastLit = Token(TokenKind.STRING_LITERAL, "::" + pgCastTypeOf("Int64"))
        extraSetParts = extraSetParts + quote(
            var vCaseParts = ArrayList<String>()
            vCaseParts.add($(caseHeadLit))
            let vCastSuffix = if (isPostgres) { $(vCastLit) } else { "" }
            for (_k_ in 0..entities.size) {
                vCaseParts.add($(whenClauseLit) + vCastSuffix)
            }
            vCaseParts.add("END")
            setParts.add($(vNameLit) + " = " + String.join(vCaseParts.toArray(), delimiter: " "))
        )
    }
    if (hasUpdatedAt) {
        let uNameLit = Token(TokenKind.STRING_LITERAL, "updated_at")
        let uCastLit = Token(TokenKind.STRING_LITERAL, "::" + pgCastTypeOf("DateTime"))
        extraSetParts = extraSetParts + quote(
            var uCaseParts = ArrayList<String>()
            uCaseParts.add($(caseHeadLit))
            let uCastSuffix = if (isPostgres) { $(uCastLit) } else { "" }
            for (_k_ in 0..entities.size) {
                uCaseParts.add($(whenClauseLit) + uCastSuffix)
            }
            uCaseParts.add("END")
            setParts.add($(uNameLit) + " = " + String.join(uCaseParts.toArray(), delimiter: " "))
        )
    }
    // 是否还有常规可更新列（编译期判断：colNames 为空且无 version/updated_at 时才抛错）
    let hasExtraSet = (versionName != "" || hasUpdatedAt)
    let hasExtraSetLit = Token(TokenKind.IDENTIFIER, if (hasExtraSet) { "true" } else { "false" })

    quote(
        func $(funcName)(entities: Array<$(cn)>, dialect: Dialect): (String, Array<Any>) {
            let colNames: Array<String> = $(colArr)
            if (colNames.size == 0 && !$(hasExtraSetLit)) { throw Exception("no updatable columns for batchUpdate") }
            let colCastTypes: Array<String> = $(castArrTok)
            let isPostgres = (dialect.name() == "postgresql")
            var allParams = ArrayList<Any>()
            $(addParams)
            var setParts = ArrayList<String>()
            for (_ci_ in 0..colNames.size) {
                var caseParts = ArrayList<String>()
                caseParts.add($(caseHeadLit))
                let castSuffix = if (isPostgres) { "::" + colCastTypes[_ci_] } else { "" }
                for (_k_ in 0..entities.size) {
                    caseParts.add($(whenClauseLit) + castSuffix)
                }
                caseParts.add("END")
                setParts.add(colNames[_ci_] + " = " + String.join(caseParts.toArray(), delimiter: " "))
            }
            $(extraSetParts)
            var inParts = ArrayList<String>()
            for (_k_ in 0..entities.size) {
                inParts.add($(inItemLit))
            }
            ("UPDATE " + $(tableNameLit) + " SET " + String.join(setParts.toArray(), delimiter: ", ") + $(whereHeadLit) + String.join(inParts.toArray(), delimiter: ", ") + ")", allParams.toArray())
        }
    )
}

func buildTxBatchUpdateExtend(className: String, fields: ArrayList<FieldInfo>): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let batchUpdateSQLFuncName = Token(TokenKind.IDENTIFIER, className + "BatchUpdateSQL")
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    let auditUpdate = buildAuditUpdateTokens(fields, "entities[_bi_]")
    let versionName = findVersionField(fields)

    if (versionName == "") {
        quote(
            extend Tx {
                public func batchUpdate(entities: Array<$(cn)>): Unit {
                    if (entities.size == 0) { return }
                    for (_bi_ in 0..entities.size) {
                        let e = entities[_bi_]
                        $(auditUpdate)
                        let scope = Scope<$(cn)>(e)
                        scope.db = Some(this)
                        if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxBeforeUpdate, scope) }
                        if (scope.aborted) { throw scope.error.getOrThrow() }
                    }
                    let (sql, params) = $(batchUpdateSQLFuncName)(entities, this.getDialect())
                    let _ = this.execute(sql, params)
                    for (_bi_ in 0..entities.size) {
                        let afterScope = Scope<$(cn)>(entities[_bi_])
                        afterScope.db = Some(this)
                        if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxAfterUpdate, afterScope) }
                    }
                }
            }
        )
    } else {
        let vIdent = Token(TokenKind.IDENTIFIER, versionName)
        quote(
            extend Tx {
                public func batchUpdate(entities: Array<$(cn)>): Unit {
                    if (entities.size == 0) { return }
                    for (_bi_ in 0..entities.size) {
                        let e = entities[_bi_]
                        $(auditUpdate)
                        let scope = Scope<$(cn)>(e)
                        scope.db = Some(this)
                        if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxBeforeUpdate, scope) }
                        if (scope.aborted) { throw scope.error.getOrThrow() }
                    }
                    let (sql, params) = $(batchUpdateSQLFuncName)(entities, this.getDialect())
                    let result = this.execute(sql, params)
                    if (result.rowCount != entities.size) {
                        throw OptimisticLockException($(nameLit), "batch", 0, -1)
                    }
                    for (_bi_ in 0..entities.size) {
                        entities[_bi_].$(vIdent) = entities[_bi_].$(vIdent) + 1
                    }
                    for (_bi_ in 0..entities.size) {
                        let afterScope = Scope<$(cn)>(entities[_bi_])
                        afterScope.db = Some(this)
                        if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxAfterUpdate, afterScope) }
                    }
                }
            }
        )
    }
}

func buildTxBatchSaveExtend(className: String, pkFields: ArrayList<FieldInfo>, hasClientPk: Bool, fields: ArrayList<FieldInfo>): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let batchInsertSQLFuncName = Token(TokenKind.IDENTIFIER, className + "BatchInsertSQL")
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    let auditCreate = buildAuditCreateTokens(fields, "entities[_bi_]")
    let versionInit = buildVersionInitTokens(fields, "entities[_bi_]")
    let preTokens = auditCreate + Token(TokenKind.NL) + versionInit

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
                        $(preTokens)
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
                        $(preTokens)
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
        if (f.isPk || isRelationField(f.typeName) || f.isVersion) { continue }
        setClauses.add(f.name + " = ?")
    }
    let versionName = findVersionField(fields)
    if (versionName != "") { setClauses.add(versionName + " = " + versionName + " + 1") }
    var sql = "UPDATE " + tableName + " SET " + String.join(setClauses.toArray(), delimiter: ", ") + buildPkWhereClause(pkFields)
    if (versionName != "") { sql = sql + " AND " + versionName + " = ?" }
    sql
}

func buildUpdateEntityArrayTokens(fields: ArrayList<FieldInfo>, pkFields: ArrayList<FieldInfo>): Tokens {
    var arr = Tokens()
    arr = arr + Token(TokenKind.LSQUARE)
    var first = true
    for (f in fields) {
        if (f.isPk || isRelationField(f.typeName) || f.isVersion) { continue }
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
    let versionName = findVersionField(fields)
    if (versionName != "") {
        if (first) { first = false } else { arr = arr + Token(TokenKind.COMMA) }
        arr = arr + Token(TokenKind.IDENTIFIER, "entity")
        arr = arr + Token(TokenKind.DOT)
        arr = arr + Token(TokenKind.IDENTIFIER, versionName)
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

func buildTxUpdateExtend(className: String, fields: ArrayList<FieldInfo>, tableName: String, pkFields: ArrayList<FieldInfo>): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let updateSQLFuncName = Token(TokenKind.IDENTIFIER, className + "UpdateSQL")
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    let auditUpdate = buildAuditUpdateTokens(fields, "entity")
    let versionName = findVersionField(fields)
    let cascadePre = quote(
        if (visitedContains(visited, entity)) { return }
        entity.cascadePreSave(this, visited)
    )
    let cascadePost = quote(entity.cascadePostSave(this, visited))

    if (versionName == "") {
        quote(
            extend Tx {
                public func update(entity: $(cn)): Unit {
                    this.updateCascade(entity, ArrayList<Object>())
                }
                public func updateCascade(entity: $(cn), visited: ArrayList<Object>): Unit {
                    $(cascadePre)
                    $(auditUpdate)
                    let scope = Scope<$(cn)>(entity)
                    scope.db = Some(this)
                    if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxBeforeUpdate, scope) }
                    if (scope.aborted) { throw scope.error.getOrThrow() }
                    let (sql, params) = $(updateSQLFuncName)(entity)
                    this.execute(sql, params)
                    $(cascadePost)
                    let afterScope = Scope<$(cn)>(entity)
                    afterScope.db = Some(this)
                    if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxAfterUpdate, afterScope) }
                }
            }
        )
    } else {
        let versionIdent = Token(TokenKind.IDENTIFIER, versionName)
        let versionSelectSQL = "SELECT " + versionName + " FROM " + tableName + buildPkWhereClause(pkFields)
        let versionSelectSQLToken = Token(TokenKind.STRING_LITERAL, versionSelectSQL)
        let pkParams = buildDeleteEntityParamsToken(pkFields)
        let pkValueExpr = buildPkValueExprTokens(pkFields)
        quote(
            extend Tx {
                public func update(entity: $(cn)): Unit {
                    this.updateCascade(entity, ArrayList<Object>())
                }
                public func updateCascade(entity: $(cn), visited: ArrayList<Object>): Unit {
                    $(cascadePre)
                    $(auditUpdate)
                    let scope = Scope<$(cn)>(entity)
                    scope.db = Some(this)
                    if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxBeforeUpdate, scope) }
                    if (scope.aborted) { throw scope.error.getOrThrow() }
                    let (sql, params) = $(updateSQLFuncName)(entity)
                    let result = this.execute(sql, params)
                    if (result.rowCount == 0) {
                        let qr = this.query($(versionSelectSQLToken), $(pkParams))
                        var actual: Int64 = -1
                        if (qr.next()) { actual = qr.get<Int64>(0 + this.getParamOffset()) }
                        qr.close()
                        throw OptimisticLockException($(nameLit), $(pkValueExpr), entity.$(versionIdent), actual)
                    }
                    entity.$(versionIdent) = entity.$(versionIdent) + 1
                    $(cascadePost)
                    let afterScope = Scope<$(cn)>(entity)
                    afterScope.db = Some(this)
                    if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxAfterUpdate, afterScope) }
                }
            }
        )
    }
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

func buildTxSoftDeleteExtend(className: String, pkFields: ArrayList<FieldInfo>): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let softDeleteSQLFuncName = Token(TokenKind.IDENTIFIER, className + "SoftDeleteSQL")
    let deleteSQLFuncName = Token(TokenKind.IDENTIFIER, className + "DeleteSQL")
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    let keyTokens = buildCascadeKeyTokens(className, pkFields, "entity")
    quote(
        extend Tx {
            public func delete(entity: $(cn)): Unit {
                this.deleteCascade(entity, ArrayList<String>())
            }
            public func deleteCascade(entity: $(cn), visited: ArrayList<String>): Unit {
                $(keyTokens)
                if (visitedKeyContains(visited, key)) { return }
                entity.cascadeDelete(this, visited)
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

func buildTxDeleteExtend(className: String, pkFields: ArrayList<FieldInfo>): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let deleteSQLFuncName = Token(TokenKind.IDENTIFIER, className + "DeleteSQL")
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    let keyTokens = buildCascadeKeyTokens(className, pkFields, "entity")
    quote(
        extend Tx {
            public func delete(entity: $(cn)): Unit {
                this.deleteCascade(entity, ArrayList<String>())
            }
            public func deleteCascade(entity: $(cn), visited: ArrayList<String>): Unit {
                $(keyTokens)
                if (visitedKeyContains(visited, key)) { return }
                entity.cascadeDelete(this, visited)
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

func buildRowMapper(className: String, cd: ClassDecl, rels: ArrayList<RelInfo>, internalNames: ArrayList<String>): Tokens {
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
                if (isGeneratedInternalField(vd.identifier.value, internalNames)) { continue }
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
            let backingIdent = Token(TokenKind.IDENTIFIER, "_" + r.fieldName)
            // ref_to 的 fk 字段在当前实体上，类型可推导（支持 String-pk 目标）；
            // has_one 的 fk 在目标表、目标 pk 类型宏层无法跨类内省，保持 Int64（has_one→String-pk 目标暂不支持）
            let idTypeTok = if (r.kind == "ref_to" && getDeclFieldType(cd, r.by) == "String") {
                Token(TokenKind.IDENTIFIER, "String")
            } else {
                Token(TokenKind.IDENTIFIER, "Int64")
            }
            assignments = assignments + Token(TokenKind.NL)
            let check = quote(
                if (columnMap.contains($(prefixCheckLit))) {
                    let $(tmpName) = $(targetType)()
                    $(tmpName).id = result.get<$(idTypeTok)>(columnMap.get($(prefixCheckLit)).getOrThrow())
                    entity.$(backingIdent) = Some($(tmpName))
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
            // 中间表目标列名固定用 lowerTableName(target) + "_id"，与 buildJunctionSchema 一致
            // （不能用 targetSchema().tableName() + "_id"，否则 @Table 覆盖表名时列名不一致）
            let targetColLit = Token(TokenKind.STRING_LITERAL, lowerTableName(r.target) + "_id")
            let joinSQL = quote(
                "SELECT " + $(tableNameExpr) + ".* FROM " + $(tableNameExpr) + " JOIN " + $(viaLit) + " ON " + $(tableNameExpr) + ".id = " + $(viaLit) + "." + $(targetColLit) + " WHERE " + $(viaLit) + "." + $(sourceSchemaIdent)().tableName() + "_id = ?"
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

            // ref_many 六件套：append / replace / delete / clear / count（load 已有）
            let cn = Token(TokenKind.IDENTIFIER, className)
            let targetParam = Token(TokenKind.IDENTIFIER, lowerTableName(r.target))
            let arrayParam = Token(TokenKind.IDENTIFIER, r.fieldName)
            let appendName = Token(TokenKind.IDENTIFIER, "append" + prefix)
            let replaceName = Token(TokenKind.IDENTIFIER, "replace" + prefix)
            let deleteName = Token(TokenKind.IDENTIFIER, "delete" + prefix)
            let clearName = Token(TokenKind.IDENTIFIER, "clear" + prefix)
            let countName = Token(TokenKind.IDENTIFIER, "count" + prefix)
            let unsavedMsg = Token(TokenKind.STRING_LITERAL,
                "ref_many " + r.fieldName + ": target " + r.target + " has empty id, save it first")
            let insertSQL = quote(
                "INSERT INTO " + $(viaLit) + " (" + $(sourceSchemaIdent)().tableName() + "_id, " + $(targetColLit) + ") VALUES (?, ?)"
            )
            let deleteSQL = quote(
                "DELETE FROM " + $(viaLit) + " WHERE " + $(sourceSchemaIdent)().tableName() + "_id = ? AND " + $(targetColLit) + " = ?"
            )
            let clearSQL = quote(
                "DELETE FROM " + $(viaLit) + " WHERE " + $(sourceSchemaIdent)().tableName() + "_id = ?"
            )
            let countSQL = quote(
                "SELECT COUNT(*) FROM " + $(viaLit) + " WHERE " + $(sourceSchemaIdent)().tableName() + "_id = ?"
            )
            let targetIdCheck = quote(
                let anyId: Any = $(targetParam).id
                let isEmpty = match (anyId) {
                    case v: Int64 => v == 0
                    case v: String => v == ""
                    case _ => false
                }
                if (isEmpty) { throw Exception($(unsavedMsg)) }
            )
            cd.body.decls.add(FuncDecl(quote(
                public func $(appendName)(tx: Tx, $(targetParam): $(targetType)): $(cn) {
                    $(targetIdCheck)
                    let sql = $(insertSQL)
                    tx.execute(sql, [this.id, $(targetParam).id])
                    this
                }
            )))
            cd.body.decls.add(FuncDecl(quote(
                public func $(appendName)(tx: Tx, $(arrayParam): Array<$(targetType)>): $(cn) {
                    for ($(targetParam) in $(arrayParam)) { this.$(appendName)(tx, $(targetParam)) }
                    this
                }
            )))
            cd.body.decls.add(FuncDecl(quote(
                public func $(replaceName)(tx: Tx, $(arrayParam): Array<$(targetType)>): $(cn) {
                    this.$(clearName)(tx)
                    this.$(appendName)(tx, $(arrayParam))
                    this
                }
            )))
            cd.body.decls.add(FuncDecl(quote(
                public func $(deleteName)(tx: Tx, $(targetParam): $(targetType)): $(cn) {
                    $(targetIdCheck)
                    let sql = $(deleteSQL)
                    tx.execute(sql, [this.id, $(targetParam).id])
                    this
                }
            )))
            cd.body.decls.add(FuncDecl(quote(
                public func $(deleteName)(tx: Tx, $(arrayParam): Array<$(targetType)>): $(cn) {
                    for ($(targetParam) in $(arrayParam)) { this.$(deleteName)(tx, $(targetParam)) }
                    this
                }
            )))
            cd.body.decls.add(FuncDecl(quote(
                public func $(clearName)(tx: Tx): $(cn) {
                    let sql = $(clearSQL)
                    tx.execute(sql, [this.id])
                    this
                }
            )))
            cd.body.decls.add(FuncDecl(quote(
                public func $(countName)(tx: Tx): Int64 {
                    let sql = $(countSQL)
                    let result = tx.query(sql, [this.id])
                    result.next()
                    result.get<Int64>(0)
                }
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

// --- Cascade Traversal Helpers ---

func getFieldTypeName(fields: ArrayList<FieldInfo>, name: String): String {
    for (f in fields) {
        if (f.name == name) { return f.typeName }
    }
    ""
}

func getDeclFieldType(cd: ClassDecl, name: String): String {
    for (i in 0..cd.body.decls.size) {
        match (cd.body.decls[i] as VarDecl) {
            case Some(vd) =>
                if (vd.identifier.value == name) { return vd.declType.toTokens().toString() }
            case _ => ()
        }
    }
    ""
}

// cascadeDelete 环检测基于 (type, id) 而非对象引用：loadX 每次新建实体实例，
// refEq 无法识别 DB 常驻环（如自引用表数据损坏成 A↔B），必须用 "<ClassName>:<pk...>" 键
// target：生成键表达式时使用的实体变量名（cascadeDelete 用 this，Tx.deleteCascade 用 entity）
func buildCascadeKeyTokens(className: String, pkFields: ArrayList<FieldInfo>, target: String): Tokens {
    let cnLit = Token(TokenKind.STRING_LITERAL, className + ":")
    let targetTok = Token(TokenKind.IDENTIFIER, target)
    if (pkFields.size == 0) {
        return quote(
            var key = $(cnLit) + $(targetTok).id.toString()
        )
    }
    let firstPk = pkFields.get(0).getOrThrow()
    var keyTokens = quote(
        var key = $(cnLit) + $(targetTok).$(Token(TokenKind.IDENTIFIER, firstPk.name)).toString()
    )
    for (i in 1..pkFields.size) {
        let pk = pkFields.get(i).getOrThrow()
        keyTokens = keyTokens + Token(TokenKind.NL) + quote(
            key = key + ":" + $(targetTok).$(Token(TokenKind.IDENTIFIER, pk.name)).toString()
        )
    }
    keyTokens
}

func buildCascadeMethods(className: String, rels: ArrayList<RelInfo>, fields: ArrayList<FieldInfo>, pkFields: ArrayList<FieldInfo>, cd: ClassDecl): Unit {
    let cn = Token(TokenKind.IDENTIFIER, className)

    // cascadePreSave：阶段 1 ref_to 维护 fk（仅标记 true 的字段）
    var preBody = Tokens()
    for (r in rels) {
        if (r.kind != "ref_to") { continue }
        let modifiedTok = Token(TokenKind.IDENTIFIER, "_" + r.fieldName + "Modified")
        let fieldTok = Token(TokenKind.IDENTIFIER, r.fieldName)
        let fkTok = Token(TokenKind.IDENTIFIER, r.by)
        let uTok = Token(TokenKind.IDENTIFIER, "u")
        let fkType = getFieldTypeName(fields, r.by)
        let zeroTok = if (fkType == "String") { Token(TokenKind.STRING_LITERAL, "") } else { Token(TokenKind.IDENTIFIER, "0") }
        if (preBody.size > 0) { preBody = preBody + Token(TokenKind.NL) + Token(TokenKind.NL) }
        preBody = preBody + quote(
            if (this.$(modifiedTok)) {
                match (this.$(fieldTok)) {
                    case Some($(uTok)) => if ($(uTok).id != $(zeroTok)) { this.$(fkTok) = $(uTok).id } else { this.$(fkTok) = $(zeroTok) }
                    case None => this.$(fkTok) = $(zeroTok)
                }
            }
        )
    }
    cd.body.decls.add(FuncDecl(quote(
        public func cascadePreSave(tx: Tx, visited: ArrayList<Object>): $(cn) {
            $(preBody)
            this
        }
    )))

    // cascadePostSave：阶段 3 has_many/has_one 回填 fk + 落库；阶段 4 ref_many 重建中间表（仅标记 true 的字段）
    // 固定顺序：has 系（阶段 3）在前，ref_many（阶段 4）在后
    var postBody = Tokens()
    for (pass in 0..2) {
        for (r in rels) {
            let isHas = (r.kind == "has_many" || r.kind == "has_one")
            let wantHas = (pass == 0)
            if (isHas != wantHas) { continue }
            let modifiedTok = Token(TokenKind.IDENTIFIER, "_" + r.fieldName + "Modified")
            let fieldTok = Token(TokenKind.IDENTIFIER, r.fieldName)
            if (r.kind == "has_many" || r.kind == "has_one") {
                let byTok = Token(TokenKind.IDENTIFIER, r.by)
                if (postBody.size > 0) { postBody = postBody + Token(TokenKind.NL) + Token(TokenKind.NL) }
                if (r.kind == "has_many") {
                    let childTok = Token(TokenKind.IDENTIFIER, "child")
                    postBody = postBody + quote(
                        if (this.$(modifiedTok)) {
                            for ($(childTok) in this.$(fieldTok)) {
                                $(childTok).$(byTok) = this.id
                                if (!visitedContains(visited, $(childTok))) {
                                    let anyId: Any = $(childTok).id
                                    match (anyId) {
                                        case v: Int64 => if (v != 0) { tx.updateCascade($(childTok), visited) } else { tx.saveCascade($(childTok), visited) }
                                        case v: String => if (v != "") { tx.updateCascade($(childTok), visited) } else { tx.saveCascade($(childTok), visited) }
                                        case _ => tx.saveCascade($(childTok), visited)
                                    }
                                }
                            }
                        }
                    )
                } else {
                    let subTok = Token(TokenKind.IDENTIFIER, "sub")
                    postBody = postBody + quote(
                        if (this.$(modifiedTok)) {
                            match (this.$(fieldTok)) {
                                case Some($(subTok)) =>
                                    $(subTok).$(byTok) = this.id
                                    if (!visitedContains(visited, $(subTok))) {
                                        let anyId: Any = $(subTok).id
                                        match (anyId) {
                                            case v: Int64 => if (v != 0) { tx.updateCascade($(subTok), visited) } else { tx.saveCascade($(subTok), visited) }
                                            case v: String => if (v != "") { tx.updateCascade($(subTok), visited) } else { tx.saveCascade($(subTok), visited) }
                                            case _ => tx.saveCascade($(subTok), visited)
                                        }
                                    }
                                case None => ()
                            }
                        }
                    )
                }
            } else if (r.kind == "ref_many") {
                let prefix = upperFirstLetter(r.fieldName)
                let clearName = Token(TokenKind.IDENTIFIER, "clear" + prefix)
                let appendName = Token(TokenKind.IDENTIFIER, "append" + prefix)
                let tTok = Token(TokenKind.IDENTIFIER, "t")
                if (postBody.size > 0) { postBody = postBody + Token(TokenKind.NL) + Token(TokenKind.NL) }
                postBody = postBody + quote(
                    if (this.$(modifiedTok)) {
                        this.$(clearName)(tx)
                        for ($(tTok) in this.$(fieldTok)) { this.$(appendName)(tx, $(tTok)) }
                    }
                )
            }
        }
    }
    cd.body.decls.add(FuncDecl(quote(
        public func cascadePostSave(tx: Tx, visited: ArrayList<Object>): $(cn) {
            if (visitedContains(visited, this)) { return this }
            visited.add(this)
            $(postBody)
            this
        }
    )))

    // cascadeDelete：先递归删子（has 系）→ 清中间表（ref_many）
    // 不依赖内存关联列表：has 系子对象通过 loadX(tx) 从库查询（含孙对象递归），再 tx.delete 逐个删
    var deleteBody = Tokens()
    for (pass in 0..2) {
        for (r in rels) {
            let isHas = (r.kind == "has_many" || r.kind == "has_one")
            let wantHas = (pass == 0)
            if (isHas != wantHas) { continue }
            let loadName = Token(TokenKind.IDENTIFIER, "load" + upperFirstLetter(r.fieldName))
            if (r.kind == "has_many" || r.kind == "has_one") {
                if (deleteBody.size > 0) { deleteBody = deleteBody + Token(TokenKind.NL) + Token(TokenKind.NL) }
                if (r.kind == "has_many") {
                    let childTok = Token(TokenKind.IDENTIFIER, "child")
                    deleteBody = deleteBody + quote(
                        for ($(childTok) in this.$(loadName)(tx)) {
                            tx.deleteCascade($(childTok), visited)
                        }
                    )
                } else {
                    let subTok = Token(TokenKind.IDENTIFIER, "sub")
                    deleteBody = deleteBody + quote(
                        match (this.$(loadName)(tx)) {
                            case Some($(subTok)) => tx.deleteCascade($(subTok), visited)
                            case None => ()
                        }
                    )
                }
            } else if (r.kind == "ref_many") {
                let prefix = upperFirstLetter(r.fieldName)
                let clearName = Token(TokenKind.IDENTIFIER, "clear" + prefix)
                if (deleteBody.size > 0) { deleteBody = deleteBody + Token(TokenKind.NL) + Token(TokenKind.NL) }
                deleteBody = deleteBody + quote(
                    this.$(clearName)(tx)
                )
            }
        }
    }
    let keyTokens = buildCascadeKeyTokens(className, pkFields, "this")
    cd.body.decls.add(FuncDecl(quote(
        public func cascadeDelete(tx: Tx, visited: ArrayList<String>): $(cn) {
            $(keyTokens)
            if (visitedKeyContains(visited, key)) { return this }
            visited.add(key)
            $(deleteBody)
            this
        }
    )))
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

func buildColumnNamesFunc(className: String, cd: ClassDecl, internalNames: ArrayList<String>): Tokens {
    let funcName = Token(TokenKind.IDENTIFIER, className + "ColumnNames")
    var columns = Tokens()
    columns = columns + Token(TokenKind.LSQUARE)
    var first = true
    for (i in 0..cd.body.decls.size) {
        match (cd.body.decls[i] as VarDecl) {
            case Some(vd) =>
                let fieldTypeStr = vd.declType.toTokens().toString()
                if (isRelationField(fieldTypeStr)) { continue }
                if (isGeneratedInternalField(vd.identifier.value, internalNames)) { continue }
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

// --- Relation Field Rewriting ---

func buildGeneratedInternalNames(rels: ArrayList<RelInfo>): ArrayList<String> {
    let names = ArrayList<String>()
    for (r in rels) {
        names.add("_" + r.fieldName)
        names.add("_" + r.fieldName + "Modified")
    }
    names
}

func isGeneratedInternalField(name: String, internalNames: ArrayList<String>): Bool {
    internalNames.contains(name)
}

func rewriteRelationFields(cd: ClassDecl, rels: ArrayList<RelInfo>): Unit {
    let relNames = ArrayList<String>()
    for (r in rels) { relNames.add(r.fieldName) }

    var i = 0
    while (i < cd.body.decls.size) {
        match (cd.body.decls[i] as VarDecl) {
            case Some(vd) =>
                let fn = vd.identifier.value
                if (relNames.contains(fn)) {
                    let backingTok = Token(TokenKind.IDENTIFIER, "_" + fn)
                    let modifiedTok = Token(TokenKind.IDENTIFIER, "_" + fn + "Modified")
                    var backingVarTokens: Tokens
                    try {
                        let initToks = vd.expr.toTokens()
                        backingVarTokens = quote(
                            internal var $(backingTok): $(vd.declType) = $(initToks)
                        )
                    } catch (e: Exception) {
                        backingVarTokens = quote(
                            internal var $(backingTok): $(vd.declType)
                        )
                    }
                    cd.body.decls.remove(at: i)
                    cd.body.decls.add(VarDecl(backingVarTokens), at: i)
                    cd.body.decls.add(VarDecl(quote(
                        public var $(modifiedTok): Bool = false
                    )), at: i + 1)
                    cd.body.decls.add(PropDecl(quote(
                        public mut prop $(vd.identifier): $(vd.declType) {
                            get() { $(backingTok) }
                            set(v) { $(backingTok) = v; $(modifiedTok) = true }
                        }
                    )), at: i + 2)
                    i += 3
                } else {
                    i++
                }
            case _ => i++
        }
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
    let versionMessages = getChildMessages("Version")
    mergedFields = applyAuditVersion(mergedFields, versionMessages)
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

    rewriteRelationFields(classDecl, mergedRels)
    let internalNames = buildGeneratedInternalNames(mergedRels)

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

    let colsStruct = buildColsStruct(className, classDecl, internalNames)
    let relClass = buildRelClass(className, mergedRels)
    let insertSQLFunc = buildInsertSQLFunc(className, mergedFields, tableName)
    let txSaveExtend = buildTxSaveExtend(className, pkFields, hasClientPk, hasAutoPk, mergedFields)
    let batchInsertSQLFunc = buildBatchInsertSQLFunc(className, mergedFields, tableName)
    let txBatchSaveExtend = buildTxBatchSaveExtend(className, pkFields, hasClientPk, mergedFields)
    let batchUpdateSQLFunc = buildBatchUpdateSQLFunc(className, mergedFields, tableName, pkFields)
    let txBatchUpdateExtend = buildTxBatchUpdateExtend(className, mergedFields)
    let updateSQLFunc = buildUpdateSQLFunc(className, mergedFields, tableName, pkFields)
    let txUpdateExtend = buildTxUpdateExtend(className, mergedFields, tableName, pkFields)
    let txUpsertExtend = buildTxUpsertExtend(className, mergedFields, tableName, pkFields)
    let rowMapper = buildRowMapper(className, classDecl, mergedRels, internalNames)
    buildRelationMethods(className, mergedRels, classDecl)
    buildCascadeMethods(className, mergedRels, mergedFields, pkFields, classDecl)
    let schemaClass = buildSchemaClass(className, mergedFields, tableName)
    let columnNamesFunc = buildColumnNamesFunc(className, classDecl, internalNames)
    var deleteSQLFunc = buildDeleteSQLFunc(className, tableName, pkFields)
    var txDeleteExtend: Tokens
    if (isSoftDelete) {
        let softDeleteSQLFunc = buildSoftDeleteSQLFunc(className, tableName, pkFields)
        txDeleteExtend = buildTxSoftDeleteExtend(className, pkFields)
        classDecl.toTokens() + Token(TokenKind.NL) + Token(TokenKind.NL) +
            colsStruct + Token(TokenKind.NL) + Token(TokenKind.NL) + relClass +
            Token(TokenKind.NL) + Token(TokenKind.NL) + insertSQLFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + txSaveExtend +
            Token(TokenKind.NL) + Token(TokenKind.NL) + batchInsertSQLFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + txBatchSaveExtend +
            Token(TokenKind.NL) + Token(TokenKind.NL) + batchUpdateSQLFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + txBatchUpdateExtend +
            Token(TokenKind.NL) + Token(TokenKind.NL) + updateSQLFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + txUpdateExtend +
            Token(TokenKind.NL) + Token(TokenKind.NL) + txUpsertExtend +
            Token(TokenKind.NL) + Token(TokenKind.NL) + deleteSQLFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + softDeleteSQLFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + txDeleteExtend +
            Token(TokenKind.NL) + Token(TokenKind.NL) + rowMapper +
            Token(TokenKind.NL) + Token(TokenKind.NL) + keyExtractorFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + columnNamesFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + schemaClass +
            junctionTokens
    } else {
        txDeleteExtend = buildTxDeleteExtend(className, pkFields)
        classDecl.toTokens() + Token(TokenKind.NL) + Token(TokenKind.NL) +
            colsStruct + Token(TokenKind.NL) + Token(TokenKind.NL) + relClass +
            Token(TokenKind.NL) + Token(TokenKind.NL) + insertSQLFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + txSaveExtend +
            Token(TokenKind.NL) + Token(TokenKind.NL) + batchInsertSQLFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + txBatchSaveExtend +
            Token(TokenKind.NL) + Token(TokenKind.NL) + batchUpdateSQLFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + txBatchUpdateExtend +
            Token(TokenKind.NL) + Token(TokenKind.NL) + updateSQLFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + txUpdateExtend +
            Token(TokenKind.NL) + Token(TokenKind.NL) + txUpsertExtend +
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

public macro Version(input: Tokens): Tokens {
    let decl = parseDecl(input)
    setItem("fieldName", decl.identifier.value)
    input
}

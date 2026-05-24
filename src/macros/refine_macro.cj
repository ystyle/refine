macro package refine.macros

import std.ast.*
import std.collection.ArrayList

func strStartsWith(s: String, prefix: String): Bool {
    if (s.size < prefix.size) { return false }
    s[0..prefix.size] == prefix
}

func strEndsWith(s: String, suffix: String): Bool {
    if (s.size < suffix.size) { return false }
    s[s.size - suffix.size..s.size] == suffix
}

func strContains(s: String, substr: String): Bool {
    if (s.size < substr.size) { return false }
    if (substr.size == 0) { return true }
    for (i in 0..s.size - substr.size + 1) {
        if (s[i..i + substr.size] == substr) { return true }
    }
    false
}

struct FieldInfo {
    var name: String
    var typeName: String
    var storageOverride: String
    public init(name: String, typeName: String, storageOverride: String) {
        this.name = name
        this.typeName = typeName
        this.storageOverride = storageOverride
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
                let info = FieldInfo(vd.identifier.value, typeStr, "")
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
        if (strContains(tn, "Option<")) {
            let start = tn.indexOf("Option<").getOrThrow() + 7
            let end = tn.lastIndexOf(">").getOrThrow()
            let targetType = tn[start..end]
            let byCol = f.name + "_id"
            let relFields = ArrayList<String>()
            relFields.add("id")
            result.add(RelInfo(f.name, "ref_to", targetType, byCol, relFields, ""))
        } else if (strContains(tn, "ArrayList<")) {
            let start = tn.indexOf("ArrayList<").getOrThrow() + 10
            let end = tn.lastIndexOf(">").getOrThrow()
            let targetType = tn[start..end]
            let relFields = ArrayList<String>()
            relFields.add("id")
            result.add(RelInfo(f.name, "ref_many", targetType, "", relFields, f.name))
        } else if (strContains(tn, "Array<")) {
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
        let fk = m.getString("fk")
        let relFields = ArrayList<String>()
        relFields.add("id")
        result.add(RelInfo(fieldName, "ref_to", target, fk, relFields, ""))
    }
    for (m in relMessages) {
        let fieldName = m.getString("fieldName")
        let kind = m.getString("kind")
        let target = m.getString("target")
        var viaOrBy = ""
        if (m.hasItem("via")) { viaOrBy = m.getString("via") }
        let relFields = ArrayList<String>()
        relFields.add("id")
        if (kind == "has_many" || kind == "has_one") {
            result.add(RelInfo(fieldName, kind, target, viaOrBy, relFields, ""))
        } else {
            result.add(RelInfo(fieldName, kind, target, "", relFields, viaOrBy))
        }
    }
    result
}

func lowerTableName(name: String): String {
    if (name.size == 0) { return name }
    let firstB = name[0]
    if (firstB >= 65u8 && firstB <= 90u8) {
        let lowerB = firstB + 32u8
        var bytes = Array<UInt8>(name.size, {i => if (i == 0) { lowerB } else { name[i] } })
        let sb = StringBuilder()
        sb.appendFromUtf8(bytes)
        sb.toString()
    } else { name }
}

func upperFirstLetter(name: String): String {
    if (name.size == 0) { return name }
    let firstB = name[0]
    if (firstB >= 97u8 && firstB <= 122u8) {
        let upperB = firstB - 32u8
        var bytes = Array<UInt8>(name.size, {i => if (i == 0) { upperB } else { name[i] } })
        let sb = StringBuilder()
        sb.appendFromUtf8(bytes)
        sb.toString()
    } else { name }
}

func isRelationField(typeName: String): Bool {
    strContains(typeName, "Option") || strContains(typeName, "ArrayList") || strContains(typeName, "Array")
}

func typeNameToStorageType(typeName: String): String {
    if (typeName == "Int8" || typeName == "Int16" || typeName == "Int32" || typeName == "Int64" ||
        typeName == "UInt8" || typeName == "UInt16" || typeName == "UInt32" || typeName == "UInt64") {
        "StorageType.Integer"
    } else if (typeName == "Float32" || typeName == "Float64") { "StorageType.Float"
    } else if (typeName == "Bool") { "StorageType.`Bool`"
    } else if (typeName == "String") { "StorageType.Text"
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
                    let $(vd.identifier): Col<$(vd.declType)> = Col<$(vd.declType)>($(Token(TokenKind.STRING_LITERAL, fn)))
                )
                first = false
            case _ => ()
        }
    }
    quote(
        struct $(colsName) { $(colsFields) init() {} }
    )
}

func buildRelClass(className: String, rels: ArrayList<RelInfo>): Tokens {
    let relClassName = Token(TokenKind.IDENTIFIER, className + "Rel")
    if (rels.size == 0) { return quote(class $(relClassName) {}) }
    var body = Tokens()
    var first = true
    for (i in 0..rels.size) {
        let r = rels[i]
        if (!first) { body = body + Token(TokenKind.NL) }
        let fieldIdent = Token(TokenKind.IDENTIFIER, r.fieldName)
        let targetType = Token(TokenKind.IDENTIFIER, r.target)
        let nameLit = Token(TokenKind.STRING_LITERAL, r.fieldName)
        let targetTableLit = Token(TokenKind.STRING_LITERAL, lowerTableName(r.target))
        if (r.kind == "ref_to") {
            let fkLit = Token(TokenKind.STRING_LITERAL, r.by)
            body = body + quote(
                static let $(fieldIdent) = RefTo<$(targetType)>($(nameLit), Col<Any>($(fkLit)), [Col<Any>("id")], $(targetTableLit))
            )
        } else if (r.kind == "has_one") {
            let fkLit = Token(TokenKind.STRING_LITERAL, r.by)
            body = body + quote(
                static let $(fieldIdent) = HasOne<$(targetType)>($(nameLit), $(fkLit), [Col<Any>("id")], $(targetTableLit))
            )
        } else if (r.kind == "has_many") {
            let fkLit = Token(TokenKind.STRING_LITERAL, r.by)
            body = body + quote(
                static let $(fieldIdent) = HasMany<$(targetType)>($(nameLit), $(fkLit), [Col<Any>("id")], $(targetTableLit))
            )
        } else {
            let viaLit = Token(TokenKind.STRING_LITERAL, r.via)
            body = body + quote(
                static let $(fieldIdent) = RefMany<$(targetType)>($(nameLit), $(viaLit), [Col<Any>("id")], $(targetTableLit))
            )
        }
        first = false
    }
    quote(class $(relClassName) { $(body) })
}

func buildSaveMethod(className: String): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    quote(
        public static func save(entity: $(cn)): Unit {
            let scope = Scope<$(cn)>(entity)
            executeHooks($(nameLit), HookKind.BeforeSave, scope)
            if (scope.aborted) { throw scope.error.getOrThrow() }
            let afterScope = Scope<$(cn)>(entity)
            executeHooks($(nameLit), HookKind.AfterSave, afterScope)
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
    var sql = "INSERT INTO " + tableName + " ("
    var first = true
    for (f in fields) {
        if (f.name == "id" || isRelationField(f.typeName)) { continue }
        if (!first) { sql = sql + ", " }
        sql = sql + f.name
        first = false
    }
    sql = sql + ") VALUES ("
    first = true
    for (f in fields) {
        if (f.name == "id" || isRelationField(f.typeName)) { continue }
        if (!first) { sql = sql + ", " }
        sql = sql + "?"
        first = false
    }
    sql = sql + ")"
    sql
}

func buildEntityArrayTokens(fields: ArrayList<FieldInfo>): Tokens {
    var arr = Tokens()
    arr = arr + Token(TokenKind.LSQUARE)
    var first = true
    for (f in fields) {
        if (f.name == "id" || isRelationField(f.typeName)) { continue }
        if (!first) { arr = arr + Token(TokenKind.COMMA) }
        arr = arr + Token(TokenKind.IDENTIFIER, "entity")
        arr = arr + Token(TokenKind.DOT)
        arr = arr + Token(TokenKind.IDENTIFIER, f.name)
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

func buildTxSaveExtend(className: String): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let insertSQLFuncName = Token(TokenKind.IDENTIFIER, className + "InsertSQL")
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    quote(
        extend Tx {
            public func save(entity: $(cn)): Unit {
                let scope = Scope<$(cn)>(entity)
                if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.BeforeSave, scope) }
                if (scope.aborted) { throw scope.error.getOrThrow() }
                let (sql, params) = $(insertSQLFuncName)(entity)
                let result = this.execute(sql, params)
                entity.id = result.lastInsertId
                let afterScope = Scope<$(cn)>(entity)
                if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.AfterSave, afterScope) }
            }
        }
    )
}

func buildUpdateSQLString(fields: ArrayList<FieldInfo>, tableName: String): String {
    var sql = "UPDATE " + tableName + " SET "
    var first = true
    for (f in fields) {
        if (f.name == "id" || isRelationField(f.typeName)) { continue }
        if (!first) { sql = sql + ", " }
        sql = sql + f.name + " = ?"
        first = false
    }
    sql = sql + " WHERE id = ?"
    sql
}

func buildUpdateEntityArrayTokens(fields: ArrayList<FieldInfo>): Tokens {
    var arr = Tokens()
    arr = arr + Token(TokenKind.LSQUARE)
    var first = true
    for (f in fields) {
        if (f.name == "id" || isRelationField(f.typeName)) { continue }
        if (!first) { arr = arr + Token(TokenKind.COMMA) }
        arr = arr + Token(TokenKind.IDENTIFIER, "entity")
        arr = arr + Token(TokenKind.DOT)
        arr = arr + Token(TokenKind.IDENTIFIER, f.name)
        first = false
    }
    arr = arr + Token(TokenKind.COMMA)
    arr = arr + Token(TokenKind.IDENTIFIER, "entity")
    arr = arr + Token(TokenKind.DOT)
    arr = arr + Token(TokenKind.IDENTIFIER, "id")
    arr = arr + Token(TokenKind.RSQUARE)
    arr
}

func buildUpdateSQLFunc(className: String, fields: ArrayList<FieldInfo>, tableName: String): Tokens {
    let funcName = Token(TokenKind.IDENTIFIER, className + "UpdateSQL")
    let cn = Token(TokenKind.IDENTIFIER, className)
    let sqlStr = buildUpdateSQLString(fields, tableName)
    let sqlToken = Token(TokenKind.STRING_LITERAL, sqlStr)
    let entityArray = buildUpdateEntityArrayTokens(fields)
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
                if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.BeforeUpdate, scope) }
                if (scope.aborted) { throw scope.error.getOrThrow() }
                let (sql, params) = $(updateSQLFuncName)(entity)
                this.execute(sql, params)
                let afterScope = Scope<$(cn)>(entity)
                if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.AfterUpdate, afterScope) }
            }
        }
    )
}

func buildDeleteSQLString(tableName: String): String { "DELETE FROM " + tableName + " WHERE id = ?" }

func buildDeleteEntityIdToken(): Tokens {
    var arr = Tokens()
    arr = arr + Token(TokenKind.LSQUARE)
    arr = arr + Token(TokenKind.IDENTIFIER, "entity")
    arr = arr + Token(TokenKind.DOT)
    arr = arr + Token(TokenKind.IDENTIFIER, "id")
    arr = arr + Token(TokenKind.RSQUARE)
    arr
}

func buildDeleteSQLFunc(className: String, tableName: String): Tokens {
    let funcName = Token(TokenKind.IDENTIFIER, className + "DeleteSQL")
    let cn = Token(TokenKind.IDENTIFIER, className)
    let sqlToken = Token(TokenKind.STRING_LITERAL, buildDeleteSQLString(tableName))
    let entityArray = buildDeleteEntityIdToken()
    quote(
        func $(funcName)(entity: $(cn)): (String, Array<Any>) { ($(sqlToken), $(entityArray)) }
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
                if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.BeforeDelete, scope) }
                if (scope.aborted) { throw scope.error.getOrThrow() }
                let (sql, params) = $(deleteSQLFuncName)(entity)
                this.execute(sql, params)
                let afterScope = Scope<$(cn)>(entity)
                if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.AfterDelete, afterScope) }
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
        let targetTable = lowerTableName(r.target)
        let mapperName = Token(TokenKind.IDENTIFIER, r.target + "RowMapper")
        let prefix = upperFirstLetter(r.fieldName)
        // Pre-compute SQL strings (must be defined before quote blocks)
        let refToSQL = Token(TokenKind.STRING_LITERAL, "SELECT * FROM " + targetTable + " WHERE id = ?")
        let hasManyLoadSQL = Token(TokenKind.STRING_LITERAL, "SELECT * FROM " + targetTable + " WHERE " + r.by + " = ?")
        let hasManyClearSQL = Token(TokenKind.STRING_LITERAL, "DELETE FROM " + targetTable + " WHERE " + r.by + " = ?")
        let hasOneLoadSQL = Token(TokenKind.STRING_LITERAL, "SELECT * FROM " + targetTable + " WHERE " + r.by + " = ?")
        let hasOneRemoveSQL = Token(TokenKind.STRING_LITERAL, "DELETE FROM " + targetTable + " WHERE " + r.by + " = ?")

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
            let via = r.via
            let joinSQL = "SELECT " + targetTable + ".* FROM " + targetTable + " JOIN " + via + " ON " + targetTable + ".id = " + via + "." + targetTable + "_id WHERE " + via + "." + sourceTable + "_id = ?"
            let joinSQLToken = Token(TokenKind.STRING_LITERAL, joinSQL)
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
            let loadSQL = Token(TokenKind.STRING_LITERAL, "SELECT * FROM " + targetTable + " WHERE " + r.by + " = ?")
            let removeSQL = Token(TokenKind.STRING_LITERAL, "DELETE FROM " + targetTable + " WHERE " + r.by + " = ?")
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

func buildSchemaClass(className: String, fields: ArrayList<FieldInfo>): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let schemaName = Token(TokenKind.IDENTIFIER, className + "Schema")
    let tableNameLit = Token(TokenKind.STRING_LITERAL, lowerTableName(className))
    var colDefs = Tokens()
    var first = true
    for (i in 0..fields.size) {
        let f = fields[i]
        if (isRelationField(f.typeName)) { continue }
        if (!first) { colDefs = colDefs + Token(TokenKind.COMMA) + Token(TokenKind.NL) }
        let nameLit = Token(TokenKind.STRING_LITERAL, f.name)
        let st = if (f.storageOverride != "") { "StorageType." + f.storageOverride } else { typeNameToStorageType(f.typeName) }
        let isId = if (f.name == "id") { "true" } else { "false" }
        colDefs = colDefs + Token(TokenKind.IDENTIFIER, "ColumnDef") + Token(TokenKind.LPAREN) + nameLit + Token(TokenKind.COMMA)
        if (f.storageOverride == "Bool" || (f.storageOverride == "" && f.typeName == "Bool")) {
            colDefs = colDefs + Token(TokenKind.IDENTIFIER, "StorageType") + Token(TokenKind.DOT)
            colDefs = colDefs + Token(TokenKind.IDENTIFIER, "`Bool`")
        } else {
            let stParts = st.split(".")
            colDefs = colDefs + Token(TokenKind.IDENTIFIER, stParts[0]) + Token(TokenKind.DOT)
            colDefs = colDefs + Token(TokenKind.IDENTIFIER, stParts[1])
        }
        colDefs = colDefs + Token(TokenKind.COMMA) + Token(TokenKind.IDENTIFIER, isId) + Token(TokenKind.COMMA)
        colDefs = colDefs + Token(TokenKind.IDENTIFIER, isId) + Token(TokenKind.COMMA)
        colDefs = colDefs + Token(TokenKind.IDENTIFIER, "false") + Token(TokenKind.RPAREN)
        first = false
    }
    quote(
        class $(schemaName) <: TableSchema {
            public func tableName(): String { $(tableNameLit) }
            public func columns(): Array<ColumnDef> { [$(colDefs)] }
            public func indexes(): Array<IndexDef> { [] }
        }
    )
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
    let mergedFields = mergeFieldOverrides(fields, fieldMessages)
    let rels = detectRelations(fields)

    let refMessages = getChildMessages("Ref")
    let relMessages = getChildMessages("Rel")
    let mergedRels = mergeAnnotationRels(rels, refMessages, relMessages)

    let mapperFuncName = Token(TokenKind.IDENTIFIER, className + "RowMapper")
    let queryTokens = quote(
        static func query(): Query<$(classNameToken)> {
            let q = Query<$(classNameToken)>()
            q.from($(Token(TokenKind.STRING_LITERAL, tableName)))
            q.setMapper($(mapperFuncName))
            q
        }
    )
    classDecl.body.decls.add(FuncDecl(queryTokens))

    let colsName = Token(TokenKind.IDENTIFIER, className + "Cols")
    let colTokens = quote(
        static func col(): $(colsName) { $(colsName)() }
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

    let colsStruct = buildColsStruct(className, classDecl)
    let relClass = buildRelClass(className, mergedRels)
    let insertSQLFunc = buildInsertSQLFunc(className, fields, tableName)
    let txSaveExtend = buildTxSaveExtend(className)
    let updateSQLFunc = buildUpdateSQLFunc(className, fields, tableName)
    let txUpdateExtend = buildTxUpdateExtend(className)
    let deleteSQLFunc = buildDeleteSQLFunc(className, tableName)
    let txDeleteExtend = buildTxDeleteExtend(className)
    let rowMapper = buildRowMapper(className, classDecl, mergedRels)
    buildRelationMethods(className, mergedRels, classDecl)
    let schemaClass = buildSchemaClass(className, mergedFields)

    classDecl.toTokens() + Token(TokenKind.NL) + Token(TokenKind.NL) +
        colsStruct + Token(TokenKind.NL) + Token(TokenKind.NL) + relClass +
        Token(TokenKind.NL) + Token(TokenKind.NL) + insertSQLFunc +
        Token(TokenKind.NL) + Token(TokenKind.NL) + txSaveExtend +
        Token(TokenKind.NL) + Token(TokenKind.NL) + updateSQLFunc +
        Token(TokenKind.NL) + Token(TokenKind.NL) + txUpdateExtend +
        Token(TokenKind.NL) + Token(TokenKind.NL) + deleteSQLFunc +
        Token(TokenKind.NL) + Token(TokenKind.NL) + txDeleteExtend +
        Token(TokenKind.NL) + Token(TokenKind.NL) + rowMapper +
        Token(TokenKind.NL) + Token(TokenKind.NL) + schemaClass
}

// --- Attribute Macros ---

public macro Ref(attr: Tokens, input: Tokens): Tokens {
    if (attr.size == 0) { return input }
    let decl = parseDecl(input)
    let fieldName = decl.identifier.value
    var target = ""
    var fk = fieldName + "_id"

    if (attr.size >= 4 && attr[2].kind == TokenKind.IDENTIFIER && attr[2].value == "target") {
        for (i in 0..attr.size) {
            if (attr[i].kind == TokenKind.IDENTIFIER && attr[i].value == "target" && i + 2 < attr.size) { target = attr[i + 2].value }
            if (attr[i].kind == TokenKind.IDENTIFIER && attr[i].value == "by" && i + 2 < attr.size) { fk = attr[i + 2].value }
        }
    } else {
        var parsingTarget = true
        for (t in attr) {
            if (t.kind == TokenKind.IDENTIFIER) {
                if (parsingTarget) { target = t.value; parsingTarget = false }
                else { fk = t.value }
            }
        }
    }
    if (target != "") {
        setItem("fieldName", fieldName); setItem("kind", "ref_to")
        setItem("target", target); setItem("fk", fk)
    }
    input
}

public macro Rel(attr: Tokens, input: Tokens): Tokens {
    if (attr.size == 0) { return input }
    let decl = parseDecl(input)
    let fieldName = decl.identifier.value
    var kind = ""; var target = ""; var viaOrBy = ""

    if (attr.size >= 4 && attr[2].kind == TokenKind.IDENTIFIER && attr[2].value == "target") {
        for (i in 0..attr.size) {
            if (attr[i].kind == TokenKind.IDENTIFIER && attr[i].value == "target" && i + 2 < attr.size) { target = attr[i + 2].value }
            if (attr[i].kind == TokenKind.IDENTIFIER && attr[i].value == "by" && i + 2 < attr.size) { viaOrBy = attr[i + 2].value }
            if (attr[i].kind == TokenKind.IDENTIFIER && attr[i].value == "via" && i + 2 < attr.size) { viaOrBy = attr[i + 2].value }
        }
        if (attr[0].kind == TokenKind.IDENTIFIER) { kind = attr[0].value }
    } else {
        var index = 0
        for (t in attr) {
            if (t.kind == TokenKind.IDENTIFIER) {
                match (index) { case 0 => kind = t.value; case 1 => target = t.value; case 2 => viaOrBy = t.value; case _ => () }
                index++
            }
        }
    }
    if (kind != "" && target != "") {
        setItem("fieldName", fieldName); setItem("kind", kind); setItem("target", target)
        if (viaOrBy != "") { setItem("via", viaOrBy) }
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

public macro Table(attr: Tokens, input: Tokens): Tokens {
    if (attr.size == 0) { return input }
    for (i in 0..attr.size) {
        if (attr[i].kind == TokenKind.STRING_LITERAL) { setItem("name", attr[i].value); return input }
    }
    input
}

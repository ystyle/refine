macro package refine.macros

import std.ast.*
import std.collection.ArrayList

func buildPkWhereClause(pkFields: ArrayList<FieldInfo>): String {
    var parts = ArrayList<String>()
    for (pk in pkFields) { parts.add(pk.name + " = ?") }
    if (parts.size == 0) { return "WHERE id = ?" }
    " WHERE " + String.join(parts.toArray(), delimiter: " AND ")
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

func buildAutoPkReturningCols(pkFields: ArrayList<FieldInfo>): String {
    var cols = ArrayList<String>()
    for (pk in pkFields) { if (pk.autoInc) { cols.add(pk.name) } }
    String.join(cols.toArray(), delimiter: ", ")
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


func buildDeleteSQLString(tableName: String, pkFields: ArrayList<FieldInfo>): String {
    "DELETE FROM " + tableName + buildPkWhereClause(pkFields)
}

func buildSoftDeleteSQLString(tableName: String, pkFields: ArrayList<FieldInfo>): String {
    "UPDATE " + tableName + " SET deleted_at = ?" + buildPkWhereClause(pkFields)
}

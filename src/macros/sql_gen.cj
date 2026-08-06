macro package refine.macros

import std.ast.*
import std.collection.ArrayList

// I19：写路径 SQL 不再把裸标识符烘焙进编译期字符串，而是生成运行时代码，
// 经 dialect.quoteIdentifier 逐处引号包裹（SQLite/PG 双引号、MySQL 反引号）。
// 生成的各 SQL 函数均接受 dialect: Dialect 参数（与 BatchUpdateSQL 既有模式一致），
// 由 tx_gen.cj 的调用方传入 this.getDialect()。

// 生成字符串数组字面量 tokens，如 ["id", "title"]
func genStringArrayTokens(names: ArrayList<String>): Tokens {
    var arr = Tokens()
    arr = arr + Token(TokenKind.LSQUARE)
    var first = true
    for (n in names) {
        if (!first) { arr = arr + Token(TokenKind.COMMA) }
        arr = arr + Token(TokenKind.STRING_LITERAL, n)
        first = false
    }
    arr = arr + Token(TokenKind.RSQUARE)
    arr
}

// 生成运行时 pk WHERE 子句构建代码，声明局部变量 pkWhere（String）。
// 前置条件：作用域内存在变量 dialect（Dialect 类型）。
func buildQuotedPkWhereTokens(pkFields: ArrayList<FieldInfo>): Tokens {
    let pkNames = ArrayList<String>()
    for (pk in pkFields) { pkNames.add(pk.columnName) }
    let pkNamesArr = genStringArrayTokens(pkNames)
    quote(
        let pkNameArr: Array<String> = $(pkNamesArr)
        var pkWhereParts = ArrayList<String>()
        for (_pw_ in pkNameArr) { pkWhereParts.add(dialect.quoteIdentifier(_pw_) + " = ?") }
        // 无 pk 退化兜底：`WHERE id = ?` 的裸 id 不加引号（与改造前行为一致，非引号化遗漏）
        let pkWhere = if (pkWhereParts.size == 0) { " WHERE id = ?" } else { " WHERE " + String.join(pkWhereParts.toArray(), delimiter: " AND ") }
    )
}

func buildInsertSQLFunc(className: String, fields: ArrayList<FieldInfo>, tableName: String): Tokens {
    let funcName = Token(TokenKind.IDENTIFIER, className + "InsertSQL")
    let cn = Token(TokenKind.IDENTIFIER, className)
    let tblLit = Token(TokenKind.STRING_LITERAL, tableName)
    var colNames = ArrayList<String>()
    for (f in fields) {
        if (shouldSkipInInsert(f)) { continue }
        colNames.add(f.columnName)
    }
    let colArr = genStringArrayTokens(colNames)
    var placeholders = ArrayList<String>()
    for (_ in 0..colNames.size) { placeholders.add("?") }
    let valuesGroup = Token(TokenKind.STRING_LITERAL, "(" + String.join(placeholders.toArray(), delimiter: ", ") + ")")
    let entityArray = buildEntityArrayTokens(fields)
    quote(
        func $(funcName)(entity: $(cn), dialect: Dialect): (String, Array<Any>) {
            let colNameArr: Array<String> = $(colArr)
            var colQuoted = ArrayList<String>()
            for (_cq_ in colNameArr) { colQuoted.add(dialect.quoteIdentifier(_cq_)) }
            let sql = "INSERT INTO " + dialect.quoteIdentifier($(tblLit)) + " (" + String.join(colQuoted.toArray(), delimiter: ", ") + ") VALUES " + $(valuesGroup)
            (sql, $(entityArray))
        }
    )
}


func buildBatchInsertSQLFunc(className: String, fields: ArrayList<FieldInfo>, tableName: String): Tokens {
    let funcName = Token(TokenKind.IDENTIFIER, className + "BatchInsertSQL")
    let cn = Token(TokenKind.IDENTIFIER, className)
    let tblLit = Token(TokenKind.STRING_LITERAL, tableName)

    var colNames = ArrayList<String>()
    var paramCount = 0
    for (f in fields) {
        if (shouldSkipInInsert(f)) { continue }
        colNames.add(f.columnName)
        paramCount++
    }
    let colArr = genStringArrayTokens(colNames)

    var qParts = ArrayList<String>()
    for (_ in 0..paramCount) { qParts.add("?") }
    let placeholderGroup = "(" + String.join(qParts.toArray(), delimiter: ", ") + ")"
    let placeholderGroupToken = Token(TokenKind.STRING_LITERAL, placeholderGroup)

    var addParams = Tokens()
    for (f in fields) {
        if (shouldSkipInInsert(f)) { continue }
        addParams = addParams + quote(
            allParams.add($(genJsonAwareFieldAccess("entities[_i_]", f.name, f.typeName)));
        )
    }

    quote(
        func $(funcName)(entities: Array<$(cn)>, dialect: Dialect): (String, Array<Any>) {
            var allParams = ArrayList<Any>()
            for (_i_ in 0..entities.size) {
                $(addParams)
            }
            var placeholders = ArrayList<String>()
            for (_j_ in 0..entities.size) {
                placeholders.add($(placeholderGroupToken))
            }
            var colQuoted = ArrayList<String>()
            let colNameArr: Array<String> = $(colArr)
            for (_cq_ in colNameArr) { colQuoted.add(dialect.quoteIdentifier(_cq_)) }
            let sql = "INSERT INTO " + dialect.quoteIdentifier($(tblLit)) + " (" + String.join(colQuoted.toArray(), delimiter: ", ") + ") VALUES " + String.join(placeholders.toArray(), delimiter: ", ")
            (sql, allParams.toArray())
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
    // M8-Json Task 3 审查（I1）：cast 类型跟随**有效存储类型**而非仓颉类型名。@Field[Json]
    // 覆盖 String 字段（schema 建 JSONB 列）时 pgCastTypeOf("String") 落 TEXT → `?::TEXT` 与
    // JSONB 目标列不匹配（SQLSTATE 42804）。eff 取 storageOverride（若显式覆盖）或
    // typeNameToStorageType 的 Json 兜底名，命中 Json → JSONB；其余仍走类型名映射。
    var setCols = ArrayList<String>()
    var colCastTypes = ArrayList<String>()
    for (f in fields) {
        if (f.isPk || isRelationField(f.typeName) || f.isVersion) { continue }
        if (f.name == "updated_at" && f.typeName == "DateTime") { continue }
        setCols.add(f.columnName)
        let eff = if (f.storageOverride != "") { f.storageOverride } else { typeNameToStorageType(f.typeName).removePrefix("StorageType.") }
        colCastTypes.add(if (eff == "Json") { "JSONB" } else { pgCastTypeOf(f.typeName) })
    }
    var pkNames = ArrayList<String>()
    for (pk in pkFields) { pkNames.add(pk.columnName) }
    // pk 名称数组字面量（运行时经 quoteIdentifier 逐一包裹后，再拼 CASE / WHEN / WHERE IN）
    let pkNamesArrTok = genStringArrayTokens(pkNames)

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
    // M8-Json Task 2: Json 兜底字段用 genJsonAwareFieldAccess 包 jsonToString。
    // I1 审查修复：参数收集直接遍历 fields（与 setCols 同一过滤：非 pk/关系/version/
    // updated_at），取 f.typeName 传给 genJsonAwareFieldAccess——消除 getFieldTypeName
    // 字符串查找（未命中返回 "" 会被 isJsonFallbackType("") 判为 Json → 全部字段被
    // jsonToString 包裹的静默损坏点）。与 batchInsert 的 `for (f in fields)` 模式一致。
    var addParams = Tokens()
    for (f in fields) {
        if (f.isPk || isRelationField(f.typeName) || f.isVersion) { continue }
        if (f.name == "updated_at" && f.typeName == "DateTime") { continue }
        addParams = addParams + quote(
            for (_bi_ in 0..entities.size) {
                $(genPkValueParamsTokens(pkFields, "entities[_bi_]"))
                allParams.add($(genJsonAwareFieldAccess("entities[_bi_]", f.name, f.typeName)));
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

    let castArrTok = castArr

    // 额外的 SET 子句（version / updated_at 独立 CASE）：caseHead/whenClause 为运行时
    // 局部变量（由上方 pkQuoted 推导），列名经 quoteIdentifier 包裹
    var extraSetParts = Tokens()
    if (versionName != "") {
        let vNameLit = Token(TokenKind.STRING_LITERAL, findVersionColumnName(fields))
        let vCastLit = Token(TokenKind.STRING_LITERAL, "::" + pgCastTypeOf("Int64"))
        extraSetParts = extraSetParts + quote(
            var vCaseParts = ArrayList<String>()
            vCaseParts.add(caseHead)
            let vCastSuffix = if (isPostgres) { $(vCastLit) } else { "" }
            for (_k_ in 0..entities.size) {
                vCaseParts.add(whenClause + vCastSuffix)
            }
            vCaseParts.add("END")
            setParts.add(dialect.quoteIdentifier($(vNameLit)) + " = " + String.join(vCaseParts.toArray(), delimiter: " "))
        )
    }
    if (hasUpdatedAt) {
        let uNameLit = Token(TokenKind.STRING_LITERAL, "updated_at")
        let uCastLit = Token(TokenKind.STRING_LITERAL, "::" + pgCastTypeOf("DateTime"))
        extraSetParts = extraSetParts + quote(
            var uCaseParts = ArrayList<String>()
            uCaseParts.add(caseHead)
            let uCastSuffix = if (isPostgres) { $(uCastLit) } else { "" }
            for (_k_ in 0..entities.size) {
                uCaseParts.add(whenClause + uCastSuffix)
            }
            uCaseParts.add("END")
            setParts.add(dialect.quoteIdentifier($(uNameLit)) + " = " + String.join(uCaseParts.toArray(), delimiter: " "))
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
            // pk 标识符运行时引号化，派生 CASE/WHEN/IN 各片段（单 pk 与复合 pk 分支见下）
            let pkNameArr: Array<String> = $(pkNamesArrTok)
            var pkQuoted = ArrayList<String>()
            for (_pq_ in pkNameArr) { pkQuoted.add(dialect.quoteIdentifier(_pq_)) }
            let singlePk = (pkQuoted.size == 1)
            var pkCondParts = ArrayList<String>()
            for (_pc_ in 0..pkQuoted.size) { pkCondParts.add(pkQuoted[_pc_] + " = ?") }
            let pkCond = String.join(pkCondParts.toArray(), delimiter: " AND ")
            var pkInParts = ArrayList<String>()
            for (_pi_ in 0..pkQuoted.size) { pkInParts.add("?") }
            let pkIn = String.join(pkInParts.toArray(), delimiter: ", ")
            let caseHead = if (singlePk) { "CASE " + pkQuoted[0] } else { "CASE" }
            let whenClause = if (singlePk) { "WHEN ? THEN ?" } else { "WHEN " + pkCond + " THEN ?" }
            let inItem = if (singlePk) { "?" } else { "(" + pkIn + ")" }
            let whereHead = if (singlePk) { " WHERE " + pkQuoted[0] + " IN (" } else { " WHERE (" + String.join(pkQuoted.toArray(), delimiter: ", ") + ") IN (" }
            var allParams = ArrayList<Any>()
            $(addParams)
            var setParts = ArrayList<String>()
            for (_ci_ in 0..colNames.size) {
                var caseParts = ArrayList<String>()
                caseParts.add(caseHead)
                let castSuffix = if (isPostgres) { "::" + colCastTypes[_ci_] } else { "" }
                for (_k_ in 0..entities.size) {
                    caseParts.add(whenClause + castSuffix)
                }
                caseParts.add("END")
                setParts.add(dialect.quoteIdentifier(colNames[_ci_]) + " = " + String.join(caseParts.toArray(), delimiter: " "))
            }
            $(extraSetParts)
            var inParts = ArrayList<String>()
            for (_k_ in 0..entities.size) {
                inParts.add(inItem)
            }
            ("UPDATE " + dialect.quoteIdentifier($(tableNameLit)) + " SET " + String.join(setParts.toArray(), delimiter: ", ") + whereHead + String.join(inParts.toArray(), delimiter: ", ") + ")", allParams.toArray())
        }
    )
}


func buildUpdateSQLFunc(className: String, fields: ArrayList<FieldInfo>, tableName: String, pkFields: ArrayList<FieldInfo>): Tokens {
    let funcName = Token(TokenKind.IDENTIFIER, className + "UpdateSQL")
    let cn = Token(TokenKind.IDENTIFIER, className)
    let tblLit = Token(TokenKind.STRING_LITERAL, tableName)
    let versionName = findVersionField(fields)
    var setCols = ArrayList<String>()
    for (f in fields) {
        if (f.isPk || isRelationField(f.typeName) || f.isVersion) { continue }
        setCols.add(f.columnName)
    }
    let setColArr = genStringArrayTokens(setCols)
    let versionLit = Token(TokenKind.STRING_LITERAL, findVersionColumnName(fields))
    let hasVersion = (versionName != "")
    let hasVersionLit = Token(TokenKind.IDENTIFIER, if (hasVersion) { "true" } else { "false" })
    let pkWhereTok = buildQuotedPkWhereTokens(pkFields)
    let entityArray = buildUpdateEntityArrayTokens(fields, pkFields)
    quote(
        func $(funcName)(entity: $(cn), dialect: Dialect): (String, Array<Any>) {
            let setColNameArr: Array<String> = $(setColArr)
            var setParts = ArrayList<String>()
            for (_su_ in setColNameArr) { setParts.add(dialect.quoteIdentifier(_su_) + " = ?") }
            if ($(hasVersionLit)) { setParts.add(dialect.quoteIdentifier($(versionLit)) + " = " + dialect.quoteIdentifier($(versionLit)) + " + 1") }
            $(pkWhereTok)
            let versionCheck = if ($(hasVersionLit)) { " AND " + dialect.quoteIdentifier($(versionLit)) + " = ?" } else { "" }
            let sql = "UPDATE " + dialect.quoteIdentifier($(tblLit)) + " SET " + String.join(setParts.toArray(), delimiter: ", ") + pkWhere + versionCheck
            (sql, $(entityArray))
        }
    )
}


func buildDeleteSQLFunc(className: String, tableName: String, pkFields: ArrayList<FieldInfo>): Tokens {
    let funcName = Token(TokenKind.IDENTIFIER, className + "DeleteSQL")
    let cn = Token(TokenKind.IDENTIFIER, className)
    let tblLit = Token(TokenKind.STRING_LITERAL, tableName)
    let pkWhereTok = buildQuotedPkWhereTokens(pkFields)
    let entityArray = buildDeleteEntityParamsToken(pkFields)
    quote(
        func $(funcName)(entity: $(cn), dialect: Dialect): (String, Array<Any>) {
            $(pkWhereTok)
            let sql = "DELETE FROM " + dialect.quoteIdentifier($(tblLit)) + pkWhere
            (sql, $(entityArray))
        }
    )
}

// M9: deletedAtIsDateTime 控制 SET deleted_at 的写值类型——Int64 软删写整数 1，
// DateTime 软删写 DateTime.now()（软删语义是"打时间戳"，与 IS NULL 过滤互补）。
func buildSoftDeleteSQLFunc(className: String, tableName: String, pkFields: ArrayList<FieldInfo>, deletedAtIsDateTime: Bool): Tokens {
    let funcName = Token(TokenKind.IDENTIFIER, className + "SoftDeleteSQL")
    let cn = Token(TokenKind.IDENTIFIER, className)
    let tblLit = Token(TokenKind.STRING_LITERAL, tableName)
    let pkWhereTok = buildQuotedPkWhereTokens(pkFields)
    let entityArray = buildSoftDeleteEntityParamsToken(pkFields, deletedAtIsDateTime)
    quote(
        func $(funcName)(entity: $(cn), dialect: Dialect): (String, Array<Any>) {
            $(pkWhereTok)
            let sql = "UPDATE " + dialect.quoteIdentifier($(tblLit)) + " SET " + dialect.quoteIdentifier("deleted_at") + " = ?" + pkWhere
            (sql, $(entityArray))
        }
    )
}

func buildSelectColumnTokens(fields: ArrayList<FieldInfo>): Tokens {
    var arr = Tokens()
    arr = arr + Token(TokenKind.LSQUARE)
    var first = true
    for (f in fields) {
        if (isRelationField(f.typeName)) { continue }
        if (!first) { arr = arr + Token(TokenKind.COMMA) }
        let colNameLit = Token(TokenKind.STRING_LITERAL, f.columnName)
        arr = arr + quote(Expr.Column($(colNameLit)))
        first = false
    }
    arr = arr + Token(TokenKind.RSQUARE)
    arr
}

// I20: RETURNING 自增主键列经 dialect.quoteIdentifier 运行时引号化。生成代码位于
// extend Tx 作用域（this 即 Tx，getDialect() 可用），声明局部变量 returningCols。
func buildAutoPkReturningCols(pkFields: ArrayList<FieldInfo>): Tokens {
    var names = ArrayList<String>()
    for (pk in pkFields) { if (pk.autoInc) { names.add(pk.columnName) } }
    let nameArr = genStringArrayTokens(names)
    quote(
        let returningNameArr: Array<String> = $(nameArr)
        var returningParts = ArrayList<String>()
        for (_rc_ in returningNameArr) { returningParts.add(this.getDialect().quoteIdentifier(_rc_)) }
        let returningCols = String.join(returningParts.toArray(), delimiter: ", ")
    )
}

// F4: PG 批量更新对 Option<DateTime> 可空标量先解包再映射（Option<DateTime> → TIMESTAMP），
// 修复前落 TEXT 兜底（`::TEXT` 与 TIMESTAMP 列的 CASE 值类型不匹配）。
func pgCastTypeOf(typeName: String): String {
    var tn = typeName
    if (isNullableScalarType(tn)) { tn = unwrapOptionType(tn) }
    match (tn) {
        case "Int8" | "Int16" | "Int32" | "Int64" | "UInt8" | "UInt16" | "UInt32" | "UInt64" => "BIGINT"
        case "Float32" | "Float64" => "DOUBLE PRECISION"
        case "Bool" => "BOOLEAN"
        case "String" => "TEXT"
        case "Array<UInt8>" => "BYTEA"
        case "DateTime" => "TIMESTAMP"
        case "Decimal" => "NUMERIC"
        // M8-Json Task 3 审查（I1）：Json 兜底的 cast 判定已上移到 batchUpdate 调用点
        //（有效存储类型 eff == "Json" → JSONB），此处不再用 isJsonFallbackType 启发式——
        // 该启发式按仓颉类型名判定，@Field[Json] 覆盖 String（JSONB 列）时类型名是 String
        // 而列是 JSONB（漏判 42804）；@Field[Text] 兜底 struct（TEXT 列）时类型名落入 Json
        // 兜底却误给 JSONB。未知类型一律 TEXT 兜底。
        case _ => "TEXT"
    }
}

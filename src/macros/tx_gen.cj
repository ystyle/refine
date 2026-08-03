macro package refine.macros

import std.ast.*
import std.collection.ArrayList

func buildTxSaveExtend(className: String, pkFields: ArrayList<FieldInfo>, hasClientPk: Bool, hasAutoPk: Bool, fields: ArrayList<FieldInfo>): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let insertSQLFuncName = Token(TokenKind.IDENTIFIER, className + "InsertSQL")
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    let auditCreate = buildAuditCreateTokens(fields, "entity")
    let versionInit = buildVersionInitTokens(fields, "entity")
    let preTokens = auditCreate + Token(TokenKind.NL) + versionInit
    // 操作层 visited 守卫（defense-in-depth）：正常流程不触发——cascadePostSave 在调用
    // saveCascade/updateCascade 前已先 `visitedContains` 预检子对象。与 deleteCascade 的
    // visitedKeyContains 守卫不同：delete 守卫是 load-bearing（cascadeDelete 子循环直接调用
    // deleteCascade 不做预检，该守卫负责环上行不重复 DELETE）
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
                    let (sql, params) = $(insertSQLFuncName)(entity, this.getDialect())
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
        let returningColsTokens = buildAutoPkReturningCols(pkFields)
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
                    let (sql, params) = $(insertSQLFuncName)(entity, this.getDialect())
                    if (this.getDialect().hasReturningSupport()) {
                        $(returningColsTokens)
                        let qr = this.query(sql + " RETURNING " + returningCols, params)
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
                    let (sql, params) = $(insertSQLFuncName)(entity, this.getDialect())
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

    let versionName = findVersionField(fields)
    let versionLit = Token(TokenKind.STRING_LITERAL, versionName)

    // 审计更新列（如 updated_at）：按 columns 顺序收集，保证追加的参数顺序与
    // 方言 upsertSQL 中 `col = ?` 的生成顺序一致（两者都按 columns 遍历）
    var auditUpdateCols = ArrayList<String>()
    for (f in fields) {
        if (isRelationField(f.typeName)) { continue }
        if (f.name == "updated_at" && hasUpdatedAt) { auditUpdateCols.add(f.name) }
    }
    var auditUpdateArr = Tokens()
    auditUpdateArr = auditUpdateArr + Token(TokenKind.LSQUARE)
    first = true
    for (c in auditUpdateCols) {
        if (!first) { auditUpdateArr = auditUpdateArr + Token(TokenKind.COMMA) }
        auditUpdateArr = auditUpdateArr + Token(TokenKind.STRING_LITERAL, c)
        first = false
    }
    auditUpdateArr = auditUpdateArr + Token(TokenKind.RSQUARE)

    // 参数：params.add(entity.field)
    var paramsTok = Tokens()
    for (f in fields) {
        if (isRelationField(f.typeName)) { continue }
        let fName = Token(TokenKind.IDENTIFIER, f.name)
        paramsTok = paramsTok + quote(
            params.add(entity.$(fName));
        )
    }
    // 审计更新列需要额外参数（如 MySQL 的 `col = ?`），是否追加由方言返回的
    // extraParamCount 决定，不再按方言名字符串特判；version 列冲突时自增不含参数。
    // 追加顺序与 columns 一致，与方言 `= ?` 的生成顺序对应。
    var auditUpdateParams = Tokens()
    for (c in auditUpdateCols) {
        if (c == versionName) { continue }
        let cTok = Token(TokenKind.IDENTIFIER, c)
        auditUpdateParams = auditUpdateParams + quote(
            params.add(entity.$(cTok));
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
                let d = this.getDialect()
                if (!d.hasUpsertSupport()) { throw Exception("upsert not supported by dialect: " + d.name()) }
                let (sql, extraCount) = d.upsertSQL($(tableNameLit), $(colsArr), $(pksArr), $(auditCreateArr), $(auditUpdateArr), $(versionLit))
                var params = ArrayList<Any>()
                $(paramsTok)
                let baseCount = params.size
                if (extraCount != 0) {
                    $(auditUpdateParams)
                }
                if (extraCount != params.size - baseCount) {
                    throw Exception("upsert extra param count mismatch expected " + extraCount.toString() + " got " + (params.size - baseCount).toString())
                }
                let _ = this.execute(sql, params.toArray())
                let afterScope = Scope<$(cn)>(entity)
                afterScope.db = Some(this)
                if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxAfterCreate, afterScope) }
            }
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
                        throw OptimisticLockException.createWithStringPk($(nameLit), "batch", 0, -1)
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
                    let (sql, params) = $(batchInsertSQLFuncName)(entities, this.getDialect())
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
                    let (sql, params) = $(batchInsertSQLFuncName)(entities, this.getDialect())
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


func buildTxUpdateExtend(className: String, fields: ArrayList<FieldInfo>, tableName: String, pkFields: ArrayList<FieldInfo>): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let updateSQLFuncName = Token(TokenKind.IDENTIFIER, className + "UpdateSQL")
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    let auditUpdate = buildAuditUpdateTokens(fields, "entity")
    let versionName = findVersionField(fields)
    // 同 buildTxSaveExtend：save/update 操作层 visited 守卫是 defense-in-depth，
    // 与 deleteCascade 的 load-bearing visitedKeyContains 守卫不对称（delete 环守卫防重复 DELETE）
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
                    let (sql, params) = $(updateSQLFuncName)(entity, this.getDialect())
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
        let versionColLit = Token(TokenKind.STRING_LITERAL, versionName)
        let tableNameLit = Token(TokenKind.STRING_LITERAL, tableName)
        let pkWhereTok = buildQuotedPkWhereTokens(pkFields)
        let pkParams = buildDeleteEntityParamsToken(pkFields)
        let pkValueExpr = buildPkValueExprTokens(pkFields)
        // M10: 按主键类型选择工厂方法——单 Int64 主键走 createWithInt64Pk，
        // 单 String 主键与复合主键（":" 拼接字符串）走 createWithStringPk，
        // 避免依赖 init 重载的隐式匹配。
        let pkIsInt64 = pkFields.size == 1 && pkFields.get(0).getOrThrow().typeName == "Int64"
        var pkFactory = Tokens()
        pkFactory = pkFactory + Token(TokenKind.IDENTIFIER, "OptimisticLockException")
        pkFactory = pkFactory + Token(TokenKind.DOT)
        pkFactory = pkFactory + Token(TokenKind.IDENTIFIER, if (pkIsInt64) { "createWithInt64Pk" } else { "createWithStringPk" })
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
                    let (sql, params) = $(updateSQLFuncName)(entity, this.getDialect())
                    let result = this.execute(sql, params)
                    if (result.rowCount == 0) {
                        let dialect = this.getDialect()
                        $(pkWhereTok)
                        let qr = this.query("SELECT " + dialect.quoteIdentifier($(versionColLit)) + " FROM " + dialect.quoteIdentifier($(tableNameLit)) + pkWhere, $(pkParams))
                        var actual: Int64 = -1
                        if (qr.next()) { actual = qr.get<Int64>(0 + this.getParamOffset()) }
                        qr.close()
                        throw $(pkFactory)($(nameLit), $(pkValueExpr), entity.$(versionIdent), actual)
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


func buildTxSoftDeleteExtend(className: String, pkFields: ArrayList<FieldInfo>): Tokens {
    let cn = Token(TokenKind.IDENTIFIER, className)
    let softDeleteSQLFuncName = Token(TokenKind.IDENTIFIER, className + "SoftDeleteSQL")
    let deleteSQLFuncName = Token(TokenKind.IDENTIFIER, className + "DeleteSQL")
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    let keyTokens = buildCascadeKeyTokens(className, pkFields, "entity")
    let deleteHookHead = quote(
        $(keyTokens)
        if (visitedKeyContains(visited, key)) { return }
        let scope = Scope<$(cn)>(entity)
        scope.db = Some(this)
        if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxBeforeDelete, scope) }
        if (scope.aborted) { throw scope.error.getOrThrow() }
    )
    let deleteAfterHooks = quote(
        let afterScope = Scope<$(cn)>(entity)
        afterScope.db = Some(this)
        if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxAfterDelete, afterScope) }
    )
    quote(
        extend Tx {
            public func delete(entity: $(cn)): Unit {
                this.deleteCascade(entity, CascadeVisitedKeys())
            }
            public func deleteCascade(entity: $(cn), visited: CascadeVisitedKeys): Unit {
                $(deleteHookHead)
                entity.cascadeDelete(this, visited)
                let (sql, params) = $(softDeleteSQLFuncName)(entity, this.getDialect())
                this.execute(sql, params)
                $(deleteAfterHooks)
            }

            public func physicalDelete(entity: $(cn)): Unit {
                this.physicalDeleteCascade(entity, CascadeVisitedKeys())
            }
            public func physicalDeleteCascade(entity: $(cn), visited: CascadeVisitedKeys): Unit {
                $(deleteHookHead)
                entity.cascadeDelete(this, visited)
                let (sql, params) = $(deleteSQLFuncName)(entity, this.getDialect())
                this.execute(sql, params)
                $(deleteAfterHooks)
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
                this.deleteCascade(entity, CascadeVisitedKeys())
            }
            public func deleteCascade(entity: $(cn), visited: CascadeVisitedKeys): Unit {
                $(keyTokens)
                if (visitedKeyContains(visited, key)) { return }
                let scope = Scope<$(cn)>(entity)
                scope.db = Some(this)
                if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxBeforeDelete, scope) }
                if (scope.aborted) { throw scope.error.getOrThrow() }
                entity.cascadeDelete(this, visited)
                let (sql, params) = $(deleteSQLFuncName)(entity, this.getDialect())
                this.execute(sql, params)
                let afterScope = Scope<$(cn)>(entity)
                afterScope.db = Some(this)
                if (this.ref.isSome()) { this.ref.getOrThrow().executeHooks($(nameLit), HookKind.TxAfterDelete, afterScope) }
            }
        }
    )
}
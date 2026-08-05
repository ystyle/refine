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

public macro Refine(input: Tokens): Tokens {
    return expandRefine(input, "none")
}

public macro Refine(attr: Tokens, input: Tokens): Tokens {
    // Task 1: 解析 @Refine[naming: "snake"] 属性宏参数——默认 "none"。
    // attr tokens 结构：naming(IDENTIFIER) :(COLON) "snake"(STRING_LITERAL)，值在 i+2。
    // 本 Task 只解析并保留 strategy 局部变量，不做任何实际转换（表名/列名仍走现有逻辑，
    // 后续 Task 用 strategy 驱动命名策略）。
    var strategy = "none"
    for (i in 0..attr.size) {
        if (attr[i].kind == TokenKind.IDENTIFIER && attr[i].value == "naming" && i + 2 < attr.size) {
            strategy = attr[i + 2].value
        }
    }
    return expandRefine(input, strategy)
}

// 共享展开逻辑：单参宏（裸 @Refine，strategy="none"）与双参宏（@Refine[naming: ...]）
// 均委托到此函数，保证两路展开完全一致。
func expandRefine(input: Tokens, strategy: String): Tokens {
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
    // M22 评审（Fix 3）: 未知 struct → Json 兜底字段发编译期 WARNING（无 TypeAdapter）
    emitUnknownTypeWarnings(classDecl, mergedFields)
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

    // Task 4: has_many/has_one 批量装配的主实体主键原始值提取器。
    // 仅单列主键生成并挂到 Query（复合主键返回空 Tokens、不 setRawIdExtractor，
    // 装配入口会抛带说明的 QueryException，见 buildRawIdExtractor 注释）。
    // R-M1：被取代的 keyExtractor（XxxKeyFromResult）已删除，仅保留 rawId 提取器。
    let rawIdExtractorFunc = buildRawIdExtractor(className, pkFields)
    let rawIdExtractorFuncName = Token(TokenKind.IDENTIFIER, className + "RawIdFromResult")
    // 复合主键（pkFields.size > 1）不 setRawIdExtractor：has_many/has_one 批量装配
    // 需要单列主键原值（目标 fk 是单列），装配入口检测 rawIdExtractor 为 None 时抛 QueryException。
    let rawIdSetterTokens = if (pkFields.size > 1) {
        Tokens()
    } else {
        quote(q.setRawIdExtractor($(rawIdExtractorFuncName));)
    }

    // Detect soft delete: has deleted_at field AND no @HardDelete annotation
    var hasDeletedAt = false
    var deletedAtIsDateTime = false
    var deletedAtNormType = ""
    for (f in mergedFields) {
        if (f.name == "deleted_at") {
            hasDeletedAt = true
            // M9 + F4: 软删过滤与写值按 deleted_at 声明类型生成——Option<DateTime> 与
            // DateTime 均视为 DateTime 语义（IS NULL 过滤 + DateTime.now() 写值），
            // Int64 保持 `= 0` / 1。归一化去空格（toTokens 渲染泛型带空格）。
            let norm = f.typeName.replace(" ", "")
            deletedAtNormType = norm
            deletedAtIsDateTime = (norm == "DateTime" || norm == "Option<DateTime>")
            break
        }
    }
    let hardDeleteMessages = getChildMessages("HardDelete")
    let isSoftDelete = hasDeletedAt && hardDeleteMessages.size == 0
    // R-I7（F4 修订）: 非 Option DateTime 的 deleted_at 会生成恒假 IS NULL 过滤——INSERT 写入
    // DateTime.now()（默认值）后该列永非 NULL，query() 永远过滤所有行（静默数据不可见）。
    // 宏层在此抛编译期错误拦截（fail-fast）；正确模型是 Option<DateTime>（过滤 IS NULL +
    // INSERT None 绑 NULL，F4 已落地），Int64 deleted_at（`= 0` 语义）是历史合法路径。
    if (isSoftDelete && deletedAtIsDateTime && deletedAtNormType != "Option<DateTime>") {
        throw Exception("soft delete field 'deleted_at' of type DateTime must be Option<DateTime> for nullable soft delete; use Int64 or Option<DateTime>")
    }

    let mapperFuncName = Token(TokenKind.IDENTIFIER, className + "RowMapper")
    let selectCols = buildSelectColumnTokens(mergedFields)
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    // Task 7: includeAll 字符串路径 DSL 需要顶层关系解析器。随 query() 挂载
    // `<实体>Rel.forName`（静态方法引用，类型 (String) -> Option<IRelation>）。
    let relResolverName = Token(TokenKind.IDENTIFIER, className + "Rel")
    // M9 + F4: 软删过滤按 deleted_at 类型生成——DateTime/Option<DateTime> 列未删状态
    // 是 NULL（IS NULL 过滤），Int64 列未删状态是 0（`= 0`）。Option<DateTime> 未删行
    // INSERT 绑 NULL，IS NULL 过滤天然命中（语义与 Int64 软删平行）。修复前
    // deletedAtIsDateTime 对 Option<DateTime> 为 false，误生成 `= 0` 过滤。
    let softDeleteFilterTokens = if (deletedAtIsDateTime) {
        quote(
            q.filter(Expr.Unary(UnaryOp.IsNull, Expr.Column("deleted_at")));
        )
    } else {
        quote(
            q.filter(Expr.Binary(Expr.Column("deleted_at"), BinOp.Eq, Expr.Value(0)));
        )
    }
    let queryTokens = if (isSoftDelete) {
        quote(
            public static func query(): Query<$(classNameToken)> {
                let q = Query<$(classNameToken)>()
                q.typeName = $(nameLit)
                q.select($(selectCols))
                q.from($(Token(TokenKind.STRING_LITERAL, tableName)))
                $(softDeleteFilterTokens)
                q.setMapper($(mapperFuncName))
                q.setRelResolver($(relResolverName).forName);
                $(rawIdSetterTokens)
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
                q.setRelResolver($(relResolverName).forName);
                $(rawIdSetterTokens)
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

    let findAllTokens = buildFindAllMethod(className)
    classDecl.body.decls.add(FuncDecl(findAllTokens))
    let findOneTokens = buildFindOneMethod(className)
    classDecl.body.decls.add(FuncDecl(findOneTokens))

    let rowMapperTokens = buildRowMapperMethod(className)
    classDecl.body.decls.add(FuncDecl(rowMapperTokens))

    // Generate junction schemas for ref_many relations
    var junctionTokens = Tokens()
    var junctionRelNames = ArrayList<String>()
    // F1: junction 源列类型跟随本类主键类型（宏层可内省）。复合主键取第一个 pk 字段；
    // 单主键即 id 字段（junction SQL 均以 this.id 为源列值）。目标列类型不可跨类内省，
    // 由 buildJunctionSchema 生成代码运行时从目标实体 Schema 读取（见 schema_gen.cj）。
    // Bool storageOverride 转义：与 buildSchemaClass:44-46 对齐——storageOverride == "Bool"
    // 时输出 StorageType.`Bool`（Bool 是仓颉关键字，裸 StorageType.Bool 生成代码编译失败）。
    var sourcePkStorage = "StorageType.Integer"
    if (pkFields.size > 0) {
        let pk = pkFields.get(0).getOrThrow()
        sourcePkStorage = if (pk.storageOverride != "") {
            if (pk.storageOverride == "Bool") { "StorageType.`Bool`" } else { "StorageType." + pk.storageOverride }
        } else { typeNameToStorageType(pk.typeName) }
    }
    for (rel in mergedRels) {
        if (rel.kind == "ref_many") {
            if (junctionRelNames.size > 0) { junctionTokens = junctionTokens + Token(TokenKind.NL) + Token(TokenKind.NL) }
            junctionTokens = junctionTokens + buildJunctionSchema(className, rel, tableName, sourcePkStorage)
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
        let softDeleteSQLFunc = buildSoftDeleteSQLFunc(className, tableName, pkFields, deletedAtIsDateTime)
        txDeleteExtend = buildTxSoftDeleteExtend(className, pkFields)
        return classDecl.toTokens() + Token(TokenKind.NL) + Token(TokenKind.NL) +
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
            Token(TokenKind.NL) + Token(TokenKind.NL) + rawIdExtractorFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + columnNamesFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + schemaClass +
            junctionTokens
    } else {
        txDeleteExtend = buildTxDeleteExtend(className, pkFields)
        return classDecl.toTokens() + Token(TokenKind.NL) + Token(TokenKind.NL) +
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
            Token(TokenKind.NL) + Token(TokenKind.NL) + rawIdExtractorFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + columnNamesFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + schemaClass +
            junctionTokens
    }
}

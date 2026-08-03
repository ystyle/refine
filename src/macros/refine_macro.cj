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

    // Task 4: has_many/has_one 批量装配的主实体主键原始值提取器。
    // 仅单列主键生成并挂到 Query（复合主键返回空 Tokens、不 setRawIdExtractor，
    // 装配入口会抛带说明的 QueryException，见 buildRawIdExtractor 注释）。
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
    for (f in mergedFields) {
        if (f.name == "deleted_at") { hasDeletedAt = true; break }
    }
    let hardDeleteMessages = getChildMessages("HardDelete")
    let isSoftDelete = hasDeletedAt && hardDeleteMessages.size == 0

    let mapperFuncName = Token(TokenKind.IDENTIFIER, className + "RowMapper")
    let selectCols = buildSelectColumnTokens(mergedFields)
    let nameLit = Token(TokenKind.STRING_LITERAL, className)
    // Task 7: includeAll 字符串路径 DSL 需要顶层关系解析器。随 query() 挂载
    // `<实体>Rel.forName`（静态方法引用，类型 (String) -> Option<IRelation>）。
    let relResolverName = Token(TokenKind.IDENTIFIER, className + "Rel")
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
                q.setKeyExtractor($(keyExtractorFuncName))
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
    // 由 buildJunctionSchema 保持 Integer（见其注释的已文档化限制）。
    var sourcePkStorage = "StorageType.Integer"
    if (pkFields.size > 0) {
        let pk = pkFields.get(0).getOrThrow()
        sourcePkStorage = if (pk.storageOverride != "") { "StorageType." + pk.storageOverride } else { typeNameToStorageType(pk.typeName) }
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
            Token(TokenKind.NL) + Token(TokenKind.NL) + rawIdExtractorFunc +
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
            Token(TokenKind.NL) + Token(TokenKind.NL) + rawIdExtractorFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + columnNamesFunc +
            Token(TokenKind.NL) + Token(TokenKind.NL) + schemaClass +
            junctionTokens
    }
}

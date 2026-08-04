macro package refine.macros

import std.ast.*
import std.collection.ArrayList

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
        // F4: Option<DateTime> 可空标量生成 nullable 列（ColumnDef 第五参 true）——
        // 否则 INSERT None 绑 NULL 会触发 DB NOT NULL 错误（硬编码 false 时该列 NOT NULL）。
        let isNullable = if (isNullableScalarType(f.typeName)) { "true" } else { "false" }
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
        colDefs = colDefs + Token(TokenKind.IDENTIFIER, isNullable) + Token(TokenKind.RPAREN)
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

// F1: junction 源列类型跟随源实体主键类型（宏层可内省 className 的 pkFields）。
// 目标列类型运行时从目标实体 Schema 读取——宏层无法跨类内省目标类主键类型
//（仓颉宏无全局符号表，已从官方文档确认），但 ref_many 依赖目标实体被 @Refine 修饰
//（其 Schema/query 方法），故 $(target)Schema() 类必然存在。columns() 运行时取目标
// 主键列 storageType：复合主键取第一个 pk 列（与源侧 refine_macro.cj:186-197 一致），
// 找不到主键列回退 Integer（防御）。目标主键 @Field storageOverride 自动生效
//（读的是 ColumnDef.storageType 最终值）。目标实体未 @Refine 时 $(target)Schema 不存在
// → 编译期失败（比 R-I9 的运行时预检更早暴露，语义也正确）。
func buildJunctionSchema(className: String, rel: RelInfo, tableName: String, sourcePkStorage: String): Tokens {
    let sourceTable = tableName
    let viaLit = Token(TokenKind.STRING_LITERAL, rel.via)
    let srcColLit = Token(TokenKind.STRING_LITERAL, sourceTable + "_id")
    let tgtColLit = Token(TokenKind.STRING_LITERAL, lowerTableName(rel.target) + "_id")
    let schemaName = Token(TokenKind.IDENTIFIER, className + "_" + upperFirstLetter(rel.fieldName) + "JunctionSchema")
    let srcStParts = sourcePkStorage.split(".")
    let srcStorageTypeTok = Token(TokenKind.IDENTIFIER, srcStParts[0])
    let srcStorageNameTok = Token(TokenKind.IDENTIFIER, srcStParts[1])
    let targetSchemaTok = Token(TokenKind.IDENTIFIER, rel.target + "Schema")
    // M24: junction 两列（源/目标 fk）构成复合主键——同一 (src,tgt) 关联天然唯一，
    // 防重复关联行；createTableSQL 对 ≥2 主键列的表渲染表级 `PRIMARY KEY (col1, col2)`。
    quote(
        public class $(schemaName) <: TableSchema {
            public func tableName(): String { $(viaLit) }
            public func columns(): Array<ColumnDef> {
                let targetSchema = $(targetSchemaTok)()
                var targetPkType = StorageType.Integer
                let tcols = targetSchema.columns()
                for (c in tcols) {
                    if (c.primaryKey) { targetPkType = c.storageType; break }
                }
                [ColumnDef($(srcColLit), $(srcStorageTypeTok).$(srcStorageNameTok), true, false, false),
                 ColumnDef($(tgtColLit), targetPkType, true, false, false)]
            }
            public func indexes(): Array<IndexDef> { [] }
        }
    )
}

func buildSchemasFunc(className: String, junctionRelNames: ArrayList<String>): Tokens {
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

macro package refine.macros

import std.ast.*
import std.collection.ArrayList


func buildRelationMethods(className: String, rels: ArrayList<RelInfo>, cd: ClassDecl): Unit {
    for (i in 0..rels.size) {
        let r = rels[i]
        let fieldIdent = Token(TokenKind.IDENTIFIER, r.fieldName)
        let targetType = Token(TokenKind.IDENTIFIER, r.target)
        let mapperName = Token(TokenKind.IDENTIFIER, r.target + "RowMapper")
        let prefix = upperFirstLetter(r.fieldName)
        let schemaIdent = Token(TokenKind.IDENTIFIER, r.target + "Schema")
        let tableNameExpr = quote($(schemaIdent)().tableName())
        // R-I6: 管理方法 SQL 标识符（目标表名、id、r.by fk 列）全部经
        // tx.getDialect().quoteIdentifier 运行时引号化（与 I21 junction 引号化对齐）。
        // 修复前裸标识符在 PG 下折叠小写，@Table["CamelCase"] 表名或驼峰 fk 无法命中。
        // 各方法均带 tx: Tx 参数（loadX/clearX/setX/removeX），故可在此取 tx.getDialect()。
        let refToSQL = quote("SELECT * FROM " + tx.getDialect().quoteIdentifier($(tableNameExpr)) + " WHERE " + tx.getDialect().quoteIdentifier("id") + " = ?")
        let hasManyLoadSQL = quote("SELECT * FROM " + tx.getDialect().quoteIdentifier($(tableNameExpr)) + " WHERE " + tx.getDialect().quoteIdentifier($(Token(TokenKind.STRING_LITERAL, r.by))) + " = ?")
        let hasManyClearSQL = quote("DELETE FROM " + tx.getDialect().quoteIdentifier($(tableNameExpr)) + " WHERE " + tx.getDialect().quoteIdentifier($(Token(TokenKind.STRING_LITERAL, r.by))) + " = ?")
        let hasOneLoadSQL = quote("SELECT * FROM " + tx.getDialect().quoteIdentifier($(tableNameExpr)) + " WHERE " + tx.getDialect().quoteIdentifier($(Token(TokenKind.STRING_LITERAL, r.by))) + " = ?")
        let hasOneRemoveSQL = quote("DELETE FROM " + tx.getDialect().quoteIdentifier($(tableNameExpr)) + " WHERE " + tx.getDialect().quoteIdentifier($(Token(TokenKind.STRING_LITERAL, r.by))) + " = ?")

        if (r.kind == "ref_to") {
            let fkField = Token(TokenKind.IDENTIFIER, r.by)
            let loadName = Token(TokenKind.IDENTIFIER, "load" + prefix)
            let getFuncName = Token(TokenKind.IDENTIFIER, "get" + prefix)
            cd.body.decls.add(FuncDecl(quote(
                public func $(loadName)(tx: Tx): Option<$(targetType)> {
                    let fk = this.$(fkField)
                    let result = tx.query($(refToSQL), [fk])
                    let offset = tx.getParamOffset()
                    let colMap = buildColumnMap(result.columnInfos, offset)
                    if (result.next()) { Some($(mapperName)(result, colMap)) } else { None }
                }
            )))
            cd.body.decls.add(FuncDecl(quote(
                public func $(getFuncName)(): Option<$(targetType)> { this.$(fieldIdent) }
            )))
        } else if (r.kind == "ref_many") {
            let sourceSchemaIdent = Token(TokenKind.IDENTIFIER, className + "Schema")
            let viaLit = Token(TokenKind.STRING_LITERAL, r.via)
            // 中间表目标列名固定用 lowerTableName(target) + "_id"，与 buildJunctionSchema 一致
            // （不能用 targetSchema().tableName() + "_id"，否则 @Table 覆盖表名时列名不一致）
            let targetColLit = Token(TokenKind.STRING_LITERAL, lowerTableName(r.target) + "_id")
            // I21：junction SQL 标识符全部经运行时 tx.getDialect().quoteIdentifier 引号化
            //（via 表名、源列 <源表>_id、目标列 <目标类>_id、目标表名、id），
            // 与批量装配读路径（assembleRefMany）对齐，PG 驼峰 via 表/列可命中。
            // 生成的方法均带 tx: Tx 参数，tx.getDialect() 可得。
            let joinSQL = quote(
                "SELECT " + tx.getDialect().quoteIdentifier($(tableNameExpr)) + ".* FROM " + tx.getDialect().quoteIdentifier($(tableNameExpr)) + " JOIN " + tx.getDialect().quoteIdentifier($(viaLit)) + " ON " + tx.getDialect().quoteIdentifier($(tableNameExpr)) + "." + tx.getDialect().quoteIdentifier("id") + " = " + tx.getDialect().quoteIdentifier($(viaLit)) + "." + tx.getDialect().quoteIdentifier($(targetColLit)) + " WHERE " + tx.getDialect().quoteIdentifier($(viaLit)) + "." + tx.getDialect().quoteIdentifier($(sourceSchemaIdent)().tableName() + "_id") + " = ?"
            )
            let joinSQLToken = joinSQL
            let loadName = Token(TokenKind.IDENTIFIER, "load" + prefix)
            let getFuncName = Token(TokenKind.IDENTIFIER, "get" + prefix)
            cd.body.decls.add(FuncDecl(quote(
                public func $(loadName)(tx: Tx): ArrayList<$(targetType)> {
                    let result = tx.query($(joinSQLToken), [this.id])
                    let offset = tx.getParamOffset()
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
            let stringPkMsg = Token(TokenKind.STRING_LITERAL,
                "ref_many " + r.fieldName + ": target " + r.target + " uses String primary key but junction target column is Integer — unimplemented, see audit R-I9")
            let insertSQL = quote(
                "INSERT INTO " + tx.getDialect().quoteIdentifier($(viaLit)) + " (" + tx.getDialect().quoteIdentifier($(sourceSchemaIdent)().tableName() + "_id") + ", " + tx.getDialect().quoteIdentifier($(targetColLit)) + ") VALUES (?, ?)"
            )
            let deleteSQL = quote(
                "DELETE FROM " + tx.getDialect().quoteIdentifier($(viaLit)) + " WHERE " + tx.getDialect().quoteIdentifier($(sourceSchemaIdent)().tableName() + "_id") + " = ? AND " + tx.getDialect().quoteIdentifier($(targetColLit)) + " = ?"
            )
            let clearSQL = quote(
                "DELETE FROM " + tx.getDialect().quoteIdentifier($(viaLit)) + " WHERE " + tx.getDialect().quoteIdentifier($(sourceSchemaIdent)().tableName() + "_id") + " = ?"
            )
            let countSQL = quote(
                "SELECT COUNT(*) FROM " + tx.getDialect().quoteIdentifier($(viaLit)) + " WHERE " + tx.getDialect().quoteIdentifier($(sourceSchemaIdent)().tableName() + "_id") + " = ?"
            )
            let targetIdCheck = quote(
                let anyId: Any = $(targetParam).id
                let isEmpty = match (anyId) {
                    case v: Int64 => v == 0
                    case v: String => v == ""
                    case _ => false
                }
                if (isEmpty) { throw Exception($(unsavedMsg)) }
                // R-I9: junction 目标列硬编码 Integer（schema_gen.cj buildJunctionSchema，
                // 宏层无法跨类内省目标主键类型），String-pk 目标会把 String id 绑进 INTEGER
                // 列 → 真实 DB 类型错误。执行前抛明确 RefineException（fail-fast，替代
                // DB 层报错）。Int64-pk 目标不受影响（case _ 分支）。has_many/has_one 走
                // fk 回填不涉及 junction 目标列，无此限制。
                match (anyId) {
                    case _: String => throw RefineException($(stringPkMsg))
                    case _ => ()
                }
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
                    let offset = tx.getParamOffset()
                    result.next()
                    result.get<Int64>(0 + offset)
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
                    entity.$(byField) = this.id
                    let anyId: Any = entity.id
                    match (anyId) {
                        case v: Int64 => if (v != 0) { tx.update(entity) } else { tx.save(entity) }
                        case v: String => if (v != "") { tx.update(entity) } else { tx.save(entity) }
                        case _ => tx.save(entity)
                    }
                    this
                }
            )))
            cd.body.decls.add(FuncDecl(quote(
                public func $(loadName)(tx: Tx): ArrayList<$(targetType)> {
                    let result = tx.query($(hasManyLoadSQL), [this.id])
                    let offset = tx.getParamOffset()
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
                    let anyId: Any = entity.id
                    let isEmpty = match (anyId) {
                        case v: Int64 => v == 0
                        case v: String => v == ""
                        case _ => false
                    }
                    if (!isEmpty) { tx.delete(entity) }
                    this
                }
            )))
        } else if (r.kind == "has_one") {
            let cn = Token(TokenKind.IDENTIFIER, className)
            let byField = Token(TokenKind.IDENTIFIER, r.by)
            let setName = Token(TokenKind.IDENTIFIER, "set" + prefix)
            let loadName = Token(TokenKind.IDENTIFIER, "load" + prefix)
            let removeName = Token(TokenKind.IDENTIFIER, "remove" + prefix)
            cd.body.decls.add(FuncDecl(quote(
                public func $(setName)(tx: Tx, entity: $(targetType)): $(cn) {
                    match (this.$(loadName)(tx)) {
                        case Some(old) => if (old.id != entity.id) { this.$(removeName)(tx) }
                        case None => ()
                    }
                    entity.$(byField) = this.id
                    let anyId: Any = entity.id
                    match (anyId) {
                        case v: Int64 => if (v != 0) { tx.update(entity) } else { tx.save(entity) }
                        case v: String => if (v != "") { tx.update(entity) } else { tx.save(entity) }
                        case _ => tx.save(entity)
                    }
                    this
                }
            )))
            cd.body.decls.add(FuncDecl(quote(
                public func $(loadName)(tx: Tx): Option<$(targetType)> {
                    let result = tx.query($(hasOneLoadSQL), [this.id])
                    let offset = tx.getParamOffset()
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

// cascadeDelete 环检测基于 (type, id) 而非对象引用：loadX 每次新建实体实例，
// refEq 无法识别 DB 常驻环（如自引用表数据损坏成 A↔B），必须用 "<ClassName>:<pk...>" 键
// target：生成键表达式时使用的实体变量名（cascadeDelete 用 this，Tx.deleteCascade 用 entity）
func buildCascadeKeyTokens(className: String, pkFields: ArrayList<FieldInfo>, target: String): Tokens {
    let cnLit = Token(TokenKind.STRING_LITERAL, className + ":")
    let targetTok = Token(TokenKind.IDENTIFIER, target)
    // pkFields 为空（实体无任何主键）在本函数中不可达：@Refine 实体要么含名为 id 的字段
    // （extractFields 默认将其标为主键，无 @Id 时 pkFields.size == 1），要么带 @Id 标注
    // （attr_macros.cj Id 宏 setItem("fieldName", 声明字段名)，applyIdAnnotations 至少标注
    // 一个字段 → size >= 1）。唯一会 size == 0 的是「既无 id 字段又无 @Id」——此时本函数
    // 生成的 `target.id` 引用根本无法编译，实体无法构建，故该退化分支是死代码。
    // 2026-08-01 审计 F2(a) 裁决：移除原 `var key = "<Class>:" + target.id.toString()`
    // 回退（误导：无主键实体并不存在），改抛明确宏错误——级联删除必须以主键键控环检测。
    if (pkFields.size == 0) {
        throw Exception("cascade methods require at least one @Id primary key field on entity " + className)
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

    // cascadePreSave：阶段 1 ref_to 维护 fk（仅标记 true 的字段，处理一次后复位标记）
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
                this.$(modifiedTok) = false
            }
        )
    }
    cd.body.decls.add(FuncDecl(quote(
        public func cascadePreSave(tx: Tx, visited: ArrayList<Object>): $(cn) {
            $(preBody)
            this
        }
    )))

    // cascadePostSave：阶段 3 has_many/has_one 回填 fk + 落库；阶段 4 ref_many 重建中间表
    // 仅处理标记 true 的字段，每个字段处理一次后复位标记（一次性语义：用户显式赋值才同步一次）
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
                            this.$(modifiedTok) = false
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
                            this.$(modifiedTok) = false
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
                        this.$(modifiedTok) = false
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
        // visited 用 CascadeVisitedKeys（= HashSet<String>，refine 包公开类型别名）：
        // 环检测键是值类型 String，HashSet 提供 O(1) contains（ArrayList 线性扫描是 O(n²)）。
        // 不用 std.collection.HashSet 全限定名——宏展开上下文中 std.collection 路径
        // 无法解析（"undeclared type name 'std'"）；别名随 refine.* 导入对用户可见。
        // 级联 save/update 的 visited 保持 ArrayList<Object>（对象引用需 refEq 语义，
        // 仓颉无 identity hash 集合，见 refine.cj visitedContains 注释）。
        public func cascadeDelete(tx: Tx, visited: CascadeVisitedKeys): $(cn) {
            $(keyTokens)
            if (visitedKeyContains(visited, key)) { return this }
            visited.add(key)
            $(deleteBody)
            this
        }
    )))
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

package refine

// M20: Query<T> DML 方法组——updateWhere/deleteWhere 及构建器侧守卫。
// 通过 extend 从 query.cj 核心类中按职责拆出。extend 不能访问被扩展类型
// 的 private 成员，故所调用的类内成员（requireExecutor/getDialect/closeExecutor）
// 与本文件内方法均已按约定改为包级可见（无修饰符），见 query.cj 顶部注释。
extend<T> Query<T> {

    public func updateWhere(setCols: Array<String>, setVals: Array<Any>): Int64 {
        rejectJoin("updateWhere")
        if (setCols.size != setVals.size) { throw QueryException("setCols and setVals must have same size") }
        if (setCols.size == 0) { throw QueryException("no columns to update") }
        let table = requireTable()
        let updater = Statement()
        updater.addClause(UpdateClause(table, setCols, setVals))
        // JOIN 已由 rejectJoin 在上游拒绝
        for (clause in stmt.clauses) {
            match (clause) {
                case WhereClause(_) => updater.addClause(clause)
                case _ => ()
            }
        }
        let exec = requireExecutor()
        try {
            let dialect = getDialect()
            let (sql, params) = dialect.render(updater)
            Logger.logSQL(sql, params)
            let result = exec.execute(sql, params)
            result.rowCount
        } finally {
            closeExecutor(exec)
        }
    }

    public func deleteWhere(): Int64 {
        rejectJoin("deleteWhere")
        let table = requireTable()
        let deleter = Statement()
        deleter.addClause(DeleteClause(table))
        // JOIN 已由 rejectJoin 在上游拒绝
        for (clause in stmt.clauses) {
            match (clause) {
                case WhereClause(_) => deleter.addClause(clause)
                case _ => ()
            }
        }
        let exec = requireExecutor()
        try {
            let dialect = getDialect()
            let (sql, params) = dialect.render(deleter)
            Logger.logSQL(sql, params)
            let result = exec.execute(sql, params)
            result.rowCount
        } finally {
            closeExecutor(exec)
        }
    }

    func getSourceTable(): String {
        for (clause in stmt.clauses) {
            match (clause) {
                case Clause.FromClause(t) => return t
                case _ => ()
            }
        }
        ""
    }

    func requireTable(): String {
        let t = getSourceTable()
        if (t == "") {
            throw QueryException("No table set. Call from() before updateWhere/deleteWhere.")
        }
        t
    }

    // 回归（I4）：updateWhere/deleteWhere 的 dialect 渲染只输出 UPDATE/DELETE + WHERE，
    // JOIN 会被静默丢弃（且 ON 参数仍进 params 导致 PG $n 错位），有误更新/误删除风险。
    // 构建器层直接拒绝：带 JOIN 的查询禁止用于 updateWhere/deleteWhere。
    // 防御依据（Task 8）：batch include 虽已不生成 include JOIN，但 Statement.addJoinClause
    // 是 public（statement.cj:27），用户仍可对 stmt 手动 addClause(JoinClause(...))，防御必须保留。
    func rejectJoin(operation: String): Unit {
        for (clause in stmt.clauses) {
            match (clause) {
                case JoinClause(_, _, _) => throw QueryException(operation + " does not support JOIN")
                case _ => ()
            }
        }
    }
}

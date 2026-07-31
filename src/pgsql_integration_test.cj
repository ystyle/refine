package refine

import std.collection.ArrayList
import std.unittest.*
import std.unittest.testmacro.*
import refine.macros.*
import pgsql.*

func tryPostgres(): Option<Refine> {
    try {
        Some(Refine.open("postgres://127.0.0.1:5432", [
            ("username", "postgres"),
            ("password", "45dbe6a6-8d1e-11ef-b01d-cb9c3f8813e2"),
            ("database", "test"),
            ("sslmode", "disable")
        ]))
    } catch (_: Exception) {
        None
    }
}

struct PgSchema <: TableSchema {
    var t: String
    var c: Array<ColumnDef>
    var i: Array<IndexDef>
    public init(name: String, cols: Array<ColumnDef>, idxs: Array<IndexDef>) {
        this.t = name; this.c = cols; this.i = idxs
    }
    public func tableName(): String { t }
    public func columns(): Array<ColumnDef> { c }
    public func indexes(): Array<IndexDef> { i }
}

@Test
public class PostgreSQLIntegrationTest {

    @TestCase
    public func testColumnDefSQL(): Unit {
        let d = PostgreSQLDialect()
        let sql1 = PostgreSQLMigrator.columnDefSQL(ColumnDef("id", StorageType.Integer, true, true, false), d)
        @Expect(sql1, "\"id\" BIGSERIAL PRIMARY KEY")
        let sql2 = PostgreSQLMigrator.columnDefSQL(ColumnDef("name", StorageType.String, false, false, false), d)
        @Expect(sql2, "\"name\" VARCHAR(255) NOT NULL")
        let sql3 = PostgreSQLMigrator.columnDefSQL(ColumnDef("bio", StorageType.Text, false, false, true), d)
        @Expect(sql3, "\"bio\" TEXT")
    }

    @TestCase
    public func testCreateTableSQL(): Unit {
        let d = PostgreSQLDialect()
        let cols = [ColumnDef("id", StorageType.Integer, true, true, false),
                    ColumnDef("name", StorageType.String, false, false, false)]
        let schema = PgSchema("test_tbl", cols, [])
        let sql = PostgreSQLMigrator.createTableSQL(schema, d)
        @Expect(sql.contains("CREATE TABLE IF NOT EXISTS"), true)
        @Expect(sql.contains("\"test_tbl\""), true)
        @Expect(sql.contains("BIGSERIAL PRIMARY KEY"), true)
    }

    @TestCase
    public func testAlterColumnReal(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                let m = rf.migrator()
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false),
                            ColumnDef("val", StorageType.String, false, false, false)]
                let schema = PgSchema("__test_pg_alt", cols, [])
                m.createTable(schema)
                m.alterColumn("__test_pg_alt",
                    ColumnDef("val", StorageType.String, false, false, false),
                    ColumnDef("val", StorageType.Text, false, false, true))
                rf.transaction { tx: Tx =>
                    let r = tx.query("SELECT data_type, is_nullable FROM information_schema.columns WHERE table_name = ? AND column_name = ?", ["__test_pg_alt", "val"])
                    if (r.next()) {
                        @Expect(r.get<String>(0), "text")
                        @Expect(r.get<String>(1), "YES")
                    } else {
                        @Expect(true, false)
                    }
                }
                m.dropTable(schema)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testAutoMigrateAltersColumn(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                let m = rf.migrator()
                let oldCols = [ColumnDef("id", StorageType.Integer, true, true, false),
                               ColumnDef("val", StorageType.String, false, false, false)]
                let schema = PgSchema("__test_pg_alt2", oldCols, [])
                m.createTable(schema)
                let newCols = [ColumnDef("id", StorageType.Integer, true, true, false),
                               ColumnDef("val", StorageType.Text, false, false, true),
                               ColumnDef("extra", StorageType.Integer, false, false, true)]
                let newSchema = PgSchema("__test_pg_alt2", newCols, [])
                m.autoMigrate([newSchema])
                rf.transaction { tx: Tx =>
                    let r = tx.query("SELECT data_type, is_nullable FROM information_schema.columns WHERE table_name = ? AND column_name = ?", ["__test_pg_alt2", "val"])
                    if (r.next()) {
                        @Expect(r.get<String>(0), "text")
                        @Expect(r.get<String>(1), "YES")
                    } else {
                        @Expect(true, false)
                    }
                    let r2 = tx.query("SELECT COUNT(*) FROM information_schema.columns WHERE table_name = ? AND column_name = ?", ["__test_pg_alt2", "extra"])
                    if (r2.next()) {
                        @Expect(r2.get<Int64>(0), 1)
                    } else {
                        @Expect(true, false)
                    }
                }
                m.dropTable(schema)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testMigratorHasTable(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                let m = rf.migrator()
                @Expect(m.hasTable("information_schema.tables"), false)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testMigratorCreateDropTable(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false)]
                let schema = PgSchema("__test_pg_mig", cols, [])
                let m = rf.migrator()
                m.createTable(schema)
                @Expect(m.hasTable("__test_pg_mig"), true)
                m.dropTable(schema)
                @Expect(m.hasTable("__test_pg_mig"), false)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testMigratorAddColumn(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false)]
                let schema = PgSchema("__test_pg_col", cols, [])
                let m = rf.migrator()
                m.createTable(schema)
                m.addColumn("__test_pg_col", ColumnDef("extra", StorageType.Text, false, false, true))
                m.dropTable(schema)
                rf.close()
                @Expect(true, true)
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testMigratorAddIndex(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false),
                            ColumnDef("name", StorageType.String, false, false, false)]
                let schema = PgSchema("__test_pg_idx", cols, [IndexDef("idx_name", ["name"])])
                let m = rf.migrator()
                m.createTable(schema)
                m.addIndex("__test_pg_idx", IndexDef("idx_name2", ["name"]))
                m.dropTable(schema)
                rf.close()
                @Expect(true, true)
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testMigratorAutoMigrate(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                let cols = [ColumnDef("id", StorageType.Integer, true, true, false),
                            ColumnDef("val", StorageType.Text, false, false, false)]
                let schema = PgSchema("__test_pg_auto", cols, [])
                let m = rf.migrator()
                m.autoMigrate([schema])
                @Expect(m.hasTable("__test_pg_auto"), true)
                m.autoMigrate([schema])
                m.dropTable(schema)
                rf.close()
                @Expect(true, true)
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testAutoMigrateWithEntitySchema(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"pgpost\"", [])
                }
                rf.migrator().autoMigrate([PgPostSchema()])
                @Expect(rf.migrator().hasTable("pgpost"), true)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testSaveAutoIncrementReturnsId(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"pgpost\"", [])
                }
                rf.migrator().autoMigrate([PgPostSchema()])
                let p = PgPost()
                p.title = "RETURNING"
                p.content = "Body"
                rf.transaction { tx: Tx => tx.save(p) }
                @Expect(p.id > 0, true)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testCrudRoundtrip(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"pgpost\"", [])
                }
                rf.migrator().autoMigrate([PgPostSchema()])
                let p = PgPost()
                p.title = "Roundtrip"
                p.content = "C1"
                rf.transaction { tx: Tx => tx.save(p) }
                @Expect(p.id > 0, true)

                let found = PgPost.query().using(rf).filter(PgPost.col().id == p.id).one()
                @Expect(found.isSome(), true)
                @Expect(found.getOrThrow().title, "Roundtrip")

                found.getOrThrow().content = "C2"
                rf.transaction { tx: Tx => tx.update(found.getOrThrow()) }
                let updated = PgPost.query().using(rf).filter(PgPost.col().id == p.id).one()
                @Expect(updated.getOrThrow().content, "C2")

                rf.transaction { tx: Tx => tx.delete(updated.getOrThrow()) }
                let gone = PgPost.query().using(rf).filter(PgPost.col().id == p.id).one()
                @Expect(gone.isNone(), true)
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testSaveStringPkWithUlid(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"pgevent\"", [])
                }
                rf.migrator().autoMigrate([PgEventSchema()])
                rf.setIdGenerator(UlidIdGenerator())
                let ev = PgEvent()
                ev.name = "deploy"
                ev.payload = "v1"
                rf.transaction { tx: Tx => tx.save(ev) }
                @Expect(ev.id != "", true)
                @Expect(ev.id.size, 26)
                let found = PgEvent.query().using(rf).filter(PgEvent.col().id == ev.id).one()
                @Expect(found.isSome(), true)
                @Expect(found.getOrThrow().name, "deploy")
                rf.close()
            case None => @Expect(true, true)
        }
    }

    @TestCase
    public func testBatchSaveStringPk(): Unit {
        match (tryPostgres()) {
            case Some(rf) =>
                rf.transaction { tx: Tx =>
                    tx.execute("DROP TABLE IF EXISTS \"pgevent\"", [])
                }
                rf.migrator().autoMigrate([PgEventSchema()])
                rf.setIdGenerator(UlidIdGenerator())
                let e1 = PgEvent(); e1.name = "a"
                let e2 = PgEvent(); e2.name = "b"
                rf.transaction { tx: Tx => tx.batchSave([e1, e2]) }
                @Expect(e1.id != "" && e2.id != "", true)
                @Expect(e1.id != e2.id, true)
                let all = PgEvent.query().using(rf).all()
                @Expect(all.size >= 2, true)
                rf.close()
            case None => @Expect(true, true)
        }
    }
}

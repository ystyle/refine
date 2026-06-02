package refine

import std.unittest.*
import std.unittest.testmacro.*

@Test
public class MySQLMigratorTest {
    @TestCase
    public func testColumnDefSQL(): Unit {
        let d = MySQLDialect()
        @Expect(MySQLMigrator.columnDefSQL(ColumnDef("name", StorageType.Text, false, false, false), d), "`name` TEXT NOT NULL")
        @Expect(MySQLMigrator.columnDefSQL(ColumnDef("id", StorageType.Integer, true, true, false), d), "`id` BIGINT AUTO_INCREMENT PRIMARY KEY")
        @Expect(MySQLMigrator.columnDefSQL(ColumnDef("email", StorageType.Text, false, false, true), d), "`email` TEXT")
    }

    @TestCase
    public func testCreateTableSQL(): Unit {
        let d = MySQLDialect()
        let sql = MySQLMigrator.createTableSQL(UserMigratorTestSchema(), d)
        let expected = "CREATE TABLE IF NOT EXISTS `user` (" +
            "`id` BIGINT AUTO_INCREMENT PRIMARY KEY, " +
            "`name` TEXT NOT NULL, " +
            "`email` TEXT, " +
            "`age` BIGINT, " +
            "`score` DOUBLE)"
        @Expect(sql, expected)
    }

    @TestCase
    public func testConstructAndCreate(): Unit {
        let db = DB(MockDatasource())
        let migrator = MySQLMigrator(db)
        migrator.createTable(UserMigratorTestSchema())
        @Expect(true, true)
    }
}

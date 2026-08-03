---
# https://vitepress.dev/reference/default-theme-home-page
layout: home

hero:
  name: "Refine ORM"
  text: "Cangjie 编译期类型安全 ORM"
  tagline: 零运行时反射 · 编译期生成 SQL · 类型安全
  actions:
    - theme: brand
      text: 快速开始
      link: /guide/getting-started
    - theme: alt
      text: API 参考
      link: /api/

features:
  - title: 类型安全
    details: 编译期类型检查，运行时零反射。实体字段映射、查询条件、关联预加载均在编译期校验。
    icon: 🛡️
  - title: 关联预加载
    details: 支持 RefTo / HasOne / HasMany / RefMany 四种关联，批量分步查询（batch include）合并同表关联，无笛卡尔积、可嵌套预加载。
    icon: 🔗
  - title: 多方言
    details: 内置 SQLite / MySQL / PostgreSQL 方言，可扩展自定义 Dialect。
    icon: 🗄️
  - title: 数据迁移
    details: 自动从实体定义生成 CREATE TABLE / ALTER TABLE，无需手写 DDL。
    icon: 📦
  - title: 事务管理
    details: 编程式事务，支持嵌套事务，自动提交/回滚。
    icon: 🔄
  - title: 生命周期钩子
    details: 事务内 TxBeforeCreate / TxAfterCreate / TxBeforeUpdate / TxAfterUpdate / TxBeforeDelete / TxAfterDelete 及 AfterFind 钩子，随真实持久化操作触发。
    icon: ⚡
---

import { defineConfig } from 'vitepress'

export default defineConfig({
  title: 'Refine ORM',
  description: 'Cangjie 编译期类型安全 ORM',
  lang: 'zh-CN',
  base: '/refine/',
  outDir: '../docs/dist',
  themeConfig: {
    nav: [
      { text: '指南', link: '/guide/getting-started' },
      { text: 'API 参考', link: '/api/' },
    ],
    sidebar: {
      '/guide/': [
        {
          text: '入门',
          items: [
            { text: '快速开始', link: '/guide/getting-started' },
            { text: '实体定义', link: '/guide/entities' },
            { text: 'CRUD 操作', link: '/guide/crud' },
            { text: '查询构建', link: '/guide/query' },
            { text: '关联预加载', link: '/guide/relations' },
            { text: '事务', link: '/guide/transactions' },
          ],
        },
        {
          text: '进阶',
          items: [
            { text: '数据迁移', link: '/guide/migrations' },
            { text: '生命周期钩子', link: '/guide/hooks' },
            { text: '配置', link: '/guide/configuration' },
          ],
        },
      ],
      '/api/': [
        {
          text: '核心 API',
          items: [
            { text: 'Refine', link: '/api/refine' },
            { text: 'Query<T>', link: '/api/query' },
            { text: 'Col<T>', link: '/api/col' },
            { text: 'Relation', link: '/api/relation' },
            { text: 'Transaction', link: '/api/transaction' },
          ],
        },
        {
          text: '扩展 API',
          items: [
            { text: 'Hook', link: '/api/hook' },
            { text: 'Migrator', link: '/api/migrator' },
            { text: 'Error', link: '/api/error' },
          ],
        },
      ],
    },
    socialLinks: [
      { icon: 'github', link: 'https://github.com/ystyle/refine' },
    ],
    footer: {
      message: 'MIT License',
    },
  },
})

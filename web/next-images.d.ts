/// <reference types="next" />
/// <reference types="next/image-types/global" />

// 位图 import（map-scene 的 terrain.png 等静态素材）的类型来源。
// next-env.d.ts 是 next dev 的再生成物且被 .gitignore——CI 的 tsc 跑在
// 无 dev 起过的干净树上，靠本文件提供 image-types 引用（knowledge：CI
// typecheck 红于 voices map-scene `Cannot find module './terrain.png'`，
// PR #807 run 35638062070 实证）。

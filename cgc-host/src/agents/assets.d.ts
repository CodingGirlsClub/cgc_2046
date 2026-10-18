// Bun 的 text import（`import x from "./x.lock" with { type: "text" }`）：打包时内联成字符串，运行时不需要文件在盘上
declare module "*.lock" {
  const text: string;
  export default text;
}
declare module "*.package.json" {
  const text: string;
  export default text;
}

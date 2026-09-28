// 以 `with { type: "file" }` 导入的图片：bun 给出文件路径（编译后是内嵌 $bunfs 路径）
declare module "*.png" {
  const path: string;
  export default path;
}

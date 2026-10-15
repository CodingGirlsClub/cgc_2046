// uninstall.ts — `uninstall` 子命令（R6）：停掉 LaunchAgent → 用学习凭证自撤销 → 删除 plist、包、状态目录与日志。
// 只在本机执行、不下载任何东西，所以平台连不上时照样能卸。课程工作目录 ~/CGC/ 是学员的作业，从不碰。
import { rmdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { revokeToken } from "./pairing";
import { loadState, stateDir } from "./state";

// 与 install.sh 写入的位置一一对应；改一边就改另一边（test/install.test.sh 装完再卸，查无残留）
const LABEL = "com.codingirlsclub.cgc-host";
const plistPath = (home: string) => join(home, "Library", "LaunchAgents", `${LABEL}.plist`);
const logPath = (home: string) => join(home, "Library", "Logs", "cgc-host.log");

export async function uninstall(home: string, apiBase: string) {
  // 先停掉常驻的 Host，免得它在删除之后又写回状态文件；没在跑时 bootout 报错，无妨
  Bun.spawnSync(["launchctl", "bootout", `gui/${process.getuid!()}/${LABEL}`], { stdout: "ignore", stderr: "ignore" });

  let revoked = true;
  try {
    const { pairing } = loadState(home);
    if (pairing) revoked = await revokeToken(apiBase, pairing.token);
  } catch {
    revoked = false; // 状态文件读不出来，就不知道该撤销哪一枚凭证
  }

  rmSync(plistPath(home), { force: true });
  rmSync(stateDir(home), { recursive: true, force: true }); // 包 cgc-host.js 也在这个目录里
  rmSync(logPath(home), { force: true });
  try {
    rmdirSync(dirname(stateDir(home))); // ~/.cgc2046 也放着 cgc-play 的 socket，空了才删
  } catch {}

  console.log("cgc-host 已卸载：LaunchAgent、程序、状态与日志都已删除；课程作业目录 ~/CGC/ 原样保留。");
  if (!revoked)
    console.log("没能向平台撤销这台电脑的学习凭证。请打开课程学习页，在对话栏的「已配对的电脑」里撤销这台电脑。");
}

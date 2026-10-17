// uninstall.ts — `uninstall` 子命令（R6）：停掉登录自启的 Host → 用学习凭证自撤销 → 删除自启项、包、状态目录与日志。
// 只在本机执行、不下载任何东西，所以平台连不上时照样能卸。课程工作目录 ~/cgc2046_workspace/ 是学员的作业、
// 学员自己的 ~/.codex 是他的账号与配置，两者都从不碰；删的只有 Host 的包、状态与页面里装的 agent。
//
// 停止与删除都按「三平台全部尽力尝试」来做：本机不存在的路径/命令删不到也停不到，都是无声的 no-op。
// 这样同一份包在任何系统上都卸得干净，测试机（macOS/CI Linux）也不必假装自己是别的系统。
import { rmdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { agentsDir } from "./agents/install";
import { revokeToken } from "./pairing";
import { loadState, stateDir } from "./state";

// 与 install.sh 写入的位置一一对应；改一边就改另一边（test/install.test.sh 装完再卸，查无残留）
const LABEL = "com.codingirlsclub.cgc-host";
const servicePaths = (home: string) => [
  join(home, "Library", "LaunchAgents", `${LABEL}.plist`), // macOS
  join(process.env.XDG_CONFIG_HOME ?? join(home, ".config"), "systemd", "user", `${LABEL}.service`), // Ubuntu
  join(process.env.APPDATA ?? join(home, "AppData", "Roaming"), "Microsoft", "Windows", "Start Menu", "Programs", "Startup", "CGC Host.cmd"), // Windows（Git Bash 路径同形）
];
const windowsLogDir = (home: string) => join(process.env.LOCALAPPDATA ?? join(home, "AppData", "Local"), "CGC");
const logPaths = (home: string) => [
  join(home, "Library", "Logs", "cgc-host.log"), // macOS
  join(process.env.XDG_STATE_HOME ?? join(home, ".local", "state"), "cgc-host.log"), // Ubuntu
  join(windowsLogDir(home), "cgc-host.log"), // Windows：stdout
  join(windowsLogDir(home), "cgc-host.error.log"), // Windows：stderr
];

/** 尽力停掉常驻的 Host；命令不存在或没在跑都无所谓，返回后状态目录才会被删 */
function stopHost() {
  const run = (argv: string[]) => {
    try {
      Bun.spawnSync(argv, { stdout: "ignore", stderr: "ignore" });
    } catch {}
  };
  if (typeof process.getuid === "function") run(["launchctl", "bootout", `gui/${process.getuid()}/${LABEL}`]);
  run(["systemctl", "--user", "disable", "--now", LABEL]);
  // Windows：按命令行匹配 cgc-host.js 的 bun 进程（.cmd 自启的 serve 实例）；排除本进程自己（uninstall 也是 bun 运行的）
  run([
    "powershell",
    "-NoProfile",
    "-Command",
    `Get-CimInstance Win32_Process -Filter "Name='bun.exe'" | Where-Object { $_.CommandLine -like '*cgc-host.js*' -and $_.ProcessId -ne ${process.pid} } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }`,
  ]);
}

export async function uninstall(home: string, apiBase: string) {
  stopHost();

  let revoked = true;
  try {
    const { pairing } = loadState(home);
    if (pairing) revoked = await revokeToken(apiBase, pairing.token);
  } catch {
    revoked = false; // 状态文件读不出来，就不知道该撤销哪一枚凭证
  }

  for (const path of [...servicePaths(home), ...logPaths(home)]) rmSync(path, { force: true });
  // 页面里装的 agent（期 2）：只删 Host 自己管的那份；学员的 ~/.codex 是他的账号与配置，从不碰
  rmSync(agentsDir(home), { recursive: true, force: true });
  rmSync(stateDir(home), { recursive: true, force: true }); // 包 cgc-host.js 也在这个目录里
  try {
    rmdirSync(windowsLogDir(home)); // 只删自己建的空目录；里面有学员别的文件就原样保留
  } catch {}
  try {
    rmdirSync(dirname(stateDir(home))); // ~/.cgc2046 也放着 cgc-play 的 socket，空了才删
  } catch {}

  console.log("cgc-host 已卸载：登录自启项、程序、状态与日志都已删除；课程作业目录 ~/cgc2046_workspace/ 原样保留。");
  if (!revoked)
    console.log("没能向平台撤销这台电脑的学习凭证。请打开课程学习页，在对话栏的「已配对的电脑」里撤销这台电脑。");
}

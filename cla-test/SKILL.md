---
name: cla-test
description: >-
  QX DSP CLA background-task (CLA BG) 的端到端 RTL 测试方法论。用于在远程服务器上对 CLA
  协处理器跑定向或随机汇编测试、对比 RTL(WO 无中断) 与参考模拟器、检查 movc2g 读到的 CR/flag
  (LVF/LUF/OVC 等)、定位 CLA 流水线相关 RTL 缺陷。**只要用户提到 CLA BG 测试、cla_bg_039 /
  cla_bg_p65 工具、run_039_bg.py / run_p65_bg.py、movc2g/movg2c、LVF/LUF/CR 标志覆盖、
  fsmul/fsadd/fsdiv 溢出下溢用例、cla_bgtask_sprs_trace、或要在 039/p65 上跑 CLA 定向汇编
  用例，就使用本 skill**——即使用户没有明说"skill"或"测试框架"。不要与偏 core0/整芯的
  dsp-kernel-auto-verification 混淆：本 skill 专注 CLA 协处理器 BG task 通道。
---

# CLA BG 测试方法论

对 QX DSP 的 CLA 协处理器（background task 通道）做 RTL 验证：编写/复用汇编测试 → 本地编译镜像 →
上传远端 → 跑 VCS 仿真（`simv_verdi`）→ 下载 trace → 解析每条 `movc2g` 读到的 CR/GR → 需要时插桩
定位 RTL 缺陷。假设本地 RTL 与远端一致；临时文件放各项目的 `agent/` 目录。

## 两个项目（先确定用哪个）

| 维度 | **p65** | **039** |
|---|---|---|
| 工具目录 | `D:\workplace\QX_Workplace\cla_bg_p65` | `D:\workplace\QX_Workplace\cla_bg_039` |
| 命令行入口 | `run_p65_bg.py` | `run_039_bg.py` |
| 配置 | `config_p65.json` | `config_039.json` |
| 远端 host | `10.18.30.200` (lx5) | `10.18.30.199` (lx4) |
| 远端 vcs | `~/Desktop/p65/vcs` | `~/Desktop/039/vcs` |
| 本地编译后端 | WSL (`as.bin`/`ld.bin`) | Windows (`as.exe`/`ld.exe`) |
| 仿真命令 | `./simv_verdi +avdd +dvdd` | `./simv_verdi -ucli -do run.do` |
| `--wo-only` 支持 | 有 | 无（默认跑 WO+W） |
| 网络 | Windows paramiko 可直连（VPN 在 Windows 时） | 经 WSL VPN，见 `references/039.md` |

**先读对应项目的参考文件**：p65 用 [references/p65.md](references/p65.md)，039 用 [references/039.md](references/039.md)。里面有各自的网络、编译、simv 处理细节。不要一次性加载两个。

## 工作流

### 阶段 0：准备
- 读对应 `config_<proj>.json`（host/sim_dir/uploads/sim_command；SSH 凭据也在里面，工具会自行读取）。
- Windows 端需要 Python + `paramiko`（脚本 SSH 依赖）。若 `import paramiko` 失败，
  `& "C:\ProgramData\Anaconda3\python.exe" -m pip install paramiko`。命令行一律用 Anaconda
  的 `python.exe` 全路径（`WindowsApps\python.exe` 是商店占位符，会失败）。

### 阶段 1：编写/放置测试用例
- 用户给了 `.s` 就用；否则按 [references/assembly.md](references/assembly.md) 写**最小、槽位忠实**的定向
  汇编。核心语法在专有 ISA 上很敏感：`||op`=slot **s2**，`|op|`=slot **s1**，`op||`=slot **s0**
  （已在 p65 用探针验证）；`movg2c GRx` 写 CR（值=GRx），`movc2g GRy` 读 CR→GRy。
  溢出/下溢/无标志的操作数配方见该参考。
- **`movc2g`/`movg2c` 读写 CR 走 CLA 内部专用通路，不经过 SPR 总线**——它们不会产生
  `spr_read_i`/`spr_write_i`。实测：CLA 执行期间连续五个采样点 `cla_r=0 cla_w=0`，
  而同期 `cla_bgtask_sprs_trace.dat` 已有 108 行写回。所以凡是要测 **SPR 通路**的场景
  （总线冲突、debug/DU 交互、门控有效性），用 `movc2g` 系列一定测不到，冲突计数会
  平凡为零——这种"用例在跑、目标通路却零活动"的假阴性最难自查。
  要产生 SPR 总线访问，须用 `load32`/`store32` 访问 `0x007f____` 地址空间：
  地址格式 `{BASE[31:16]=0x007f, GROUP[15:8], OFS[7:0]}`，组号
  PIC=1、DU=2、TIMER=3、CR=4、GR=5、MOB=6、WD=8（如 TIMER 组基址 `0x007f0300`）。
  判据：先确认活动量计数 `>0`，再看冲突计数才有意义。
- 放到 `cla_bg_<proj>\custom_random\<名字>.s`。多组扫描类用例用脚本生成（见 assembly 参考）。

### 阶段 2：本地编译镜像
- 跑工具本地构建（不联网）确认汇编语法有效：
  `python run_<proj>_bg.py --skip-generate --source custom_random\<file>.s --case <名字> --no-remote-run --no-reference-sim`
- 产物在 `output\<时间>_<case>\work\Release_wo\`：`dram_image.core0.dat` / `iram_image.core0.dat` /
  `dram_image.cla0.dat` / `iram_image.cla0.dat`。CLA 指令码在 `iram_image.cla0.dat`。
- **四件套是一组，必须整体上传，不能只换 `cla0` 那两个**。CLA 不会自启动：
  `iram_image.core0.dat` 里的 core0 程序负责**使能 CLA 时钟**并**触发 BG task**。
  只换 CLA 镜像、core0 用别的程序，症状是 CLA 有时钟（`clk_edges` 正常增长）
  但 **PC 恒为 0、完全不取指、trace 为空**——很容易误判成 CLA 坏了或镜像装错地址。
  走工具 remote 流程不会错（`config` 的 `uploads` 就是四个一起传）；手动 `scp` 时才需当心。
  对应关系：`iram_image.core0.dat`→`outer_insn_mem_core0.dat`、
  `dram_image.core0.dat`→`outer_data_mem_core0.dat`、
  `iram_image.cla0.dat`→`outer_insn_mem_cla0.dat`、
  `dram_image.cla0.dat`→`outer_data_mem_cla0.dat`。

### 阶段 3：远端仿真
- **每次 P65 测试前**必查 `~/Desktop/p65/fpga/c2000_tb.v`，有效超时必须准确为 `#80000000`（80ms）且会 `$finish`；不一致时先修正、再次核对并重新编译。其它项目编译前仍需确认有限超时和 `$finish`。
- `config` 的 `sim_command` 常写 `./simv`，但远端通常只有 `simv_verdi`。要么改本地 config 的
  `sim_command` 用 `./simv_verdi`，要么手动跑。**手动跑时必须保留 `printf 'exit\n' |` 管道**，
  写作 `printf 'exit\n' | ./simv_verdi +avdd +dvdd`——`config` 里那个管道不是摆设：
  tb 里可能有 `$stop`（p65 的 `cmsdk_uart_capture_ard.v:266`，UART 测试结束时触发，
  实测在 63.2ms），一旦触发就进入 **ucli 交互模式**，会把脚本剩余命令当成 ucli 输入吃掉
  （报 `invalid command name grep`），整轮结果静默丢失，**而退出码仍然是 0**。
  注：`$stop` 会反复触发，喂 `run` 无法越过（每次只前进百来 ns）；若需跑满 tb 超时，
  只能临时注释掉那处 `$stop` 并在收尾时恢复。
  **若 `simv_verdi` 不存在或需重编**：用 `agent_compile.sh`（设了 `PRJ_P65` 环境变量
  + `+define+CLA_BGTASK_REG2DAT`）——直接 `make comp_verdi` 会因
  `filelist_sim=$(PRJ_P65)/...` 解析成绝对路径而失败。
- **二进制新鲜度门禁（重要）**：远端现成 `simv_verdi` **不保证**反映当前 RTL——它可能是几周前编的旧版，
  会掩盖真实行为（本 skill 就踩过：039 复用旧二进制得"无覆盖"，重编当前 RTL 后 N=0/1 实为覆盖）。
  复用前先核实其新鲜度（比对 `simv_verdi` 时间戳与 `~/Desktop/<proj>/rtl` 最新改动，或直接重编）。
  **凡是要给出"无 bug / 无覆盖 / 与模拟器一致 / 行为正确"这类负结论或 RTL 正确性判断，必须在当前 RTL
  重新编译后的二进制上得出**；否则只能标注"基于复用二进制、非结论性"。快速复现/已知新鲜的二进制可复用，不必每次重编。
- 若能用工具的 remote 流程（p65 从 Windows 直连）：去掉 `--no-remote-run`，加 `--wo-only`（p65）跑
  WO/模拟器对比。**否则（039）走手动 WSL 上传/仿真/下载**，见 `references/039.md`。
- 远端登录 shell 是 **csh**：远程命令里**绝不能**用 `2>&1` / `2>/dev/null`（会被当文件名）；
  用 `ssh HOST bash -s < 本地脚本` 把命令喂给远端 bash，彻底绕开引号/csh 问题。

### 阶段 4：解析 trace
- Trace 文件 `cla_bgtask_sprs_trace.dat`（含 NUL，用 `grep`/`tr -d '\000'` 处理，别整读为文本）。
  行格式 `reg\tvalue\tpc\t[time]`。`GR20 = 0x14`。CR 位：**bit1=LUF、bit2=LVF、bit14=EALLOW**
  （`0x4004`=LVF 置位、`0x4002`=LUF 置位、`0x4006`=两者都置、`0x4000`=都清）。
- 每条 `movc2g GR20` 产生一行 `0x14`，按程序顺序对应各组。解析方法与已知 CR 流水冒险见
  [references/trace-and-probe.md](references/trace-and-probe.md)。

### 阶段 5（按需）：插桩定位 RTL
- 受限 `$display` 探针，用强触发条件（时间窗/PC/flag 信号）约束，输出 <1000 行；最终 RTL 里
  **不留探针**。改本地 RTL → 上传 → `agent_compile.sh` 重编 → 重跑。已知 CR 相关缺陷与探针位点
  见 `references/trace-and-probe.md`。

## 报告
按：**用例意图 → 每组 movc2g 的 CR 结果表（含期望值 vs 实测）→ 结论（哪些情况覆盖/丢标志/正确）
→（若定位到 RTL）文件:行 + 机理 + 证据**。涉及 FPU/舍入/特殊值的，覆盖 ±inf/±0/溢出/下溢相关组合。
**报告须注明本次 `simv_verdi` 的来源**（当前 RTL 重编 / 复用现成，含时间戳），让结论可审计——尤其负结论
必须能追溯到"跑在当前 RTL 上"。

## 硬规则
- **负结论门禁**：任何"无 bug / 无覆盖 / 一致 / 行为正确"的结论，必须建立在**当前 RTL 重编后**的
  `simv_verdi` 上；复用来路不明或过期二进制得出的负结论一律标注"非结论性"，不得当定论。
- 每次 P65 测试前必查 `c2000_tb.v`，确认有效超时为 `#80000000` 且最终执行 `$finish`；不一致时必须先修正并重新编译。
- 探针 <1000 行、强触发、用后即删；不加无约束 `$display`/`$monitor`。
- 凭据按常规安全习惯处理：优先 SSH 密钥或让工具自行从 `config` 读取；不要把密码等秘密写进命令行参数
  （会进 shell 历史/日志）。远端交互式认证注意 pam_faillock/fail2ban，认证一次成功、不要循环重试。
- 远端 csh：远程命令避免重定向，用 `bash -s < script`。
- 不改无关 RTL，不还原用户改动，临时文件进 `cla_bg_<proj>\agent\`。

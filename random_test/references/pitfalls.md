# random_test 历史坑点与误判复盘

这份文档记录已经踩过、已定位、已修复的问题。出现类似现象时先来这里对照，能省下大量重复排查。
读法：每条给出**现象 → 真因 → 处置**。

## 一、对齐类

### 1. BASE_PC 取值（2026-07-01 结论已被 2026-07-21 推翻）

**当前正确值：`BASE_PC = 0x00028400`。**

- **2026-07-01 曾把它从 `0x00028400` 改成 `0x00280000`**，理由是"chip trace 首个写回的 PC 是 `0x00280000`"，并记录对齐率从 ~50% 升到 99.7%。
- **2026-07-21 证明这个理由是错的**：chip trace 开头约 51 行是 **bootloader**（装载在 `0x280000`）的写回，测试镜像并不在那里。用 PC 区段切换点看得很清楚：

  ```
  行1     0x00280000  BOOT      ← bootloader，不是测试码
  行52    0x00028400  TEST      ← 测试码真正的起点
  行136   0x002805d0  BOOT      ← 跳错地址，飞回 bootloader 区，挂死
  ```

- **`0x00280000` 的失效模式很隐蔽**：初始化是顺序执行的，所以前 126 行与 ISS **逐条完美对齐**，看不出任何异常；但函数/跳转目标被算成 `0x280000+offset` 落进 bootloader 区，核跳过去执行两条就挂死。chip trace 固定停在 137 行。
  - 关键鉴别：**加大 TB 超时后 trace 的 md5 完全不变**（200ms 与 400ms 逐字节相同）。这说明不是时间不够，是核停了。
- **交叉验证 `0x00028400` 正确**：哨兵 `0xDEADBEEF` 落在 `0x0002853c` = `0x28400 + 0x13c`，紧接生成器标注的 `initial addr` 偏移 `0x140`。改回后 chip trace 从 137 行 → 1075 行。
- **注意连带影响**：数据区由 `BASE_PC` 推导（`tool/ram.py:81`），改它会改变随机 store 的落点。

**教训**：不要用 chip trace 的首行 PC 当测试码起点——那是 bootloader。要找 BOOT→TEST 的区段切换点。

### 2. boot 阶段写回污染开头

- **处置**：`instr_generate/txt/start.py` 在测试体前插入 GR0~GR29 + CR 初始化，末尾写哨兵 `GR0 = 0xDEADBEEF`；`script/compare.py` 定位到哨兵后才开始比较。
- **注意**：`SENTINEL_VALUE` 在 `start.py` 和 `compare.py:11` 两处，改一处必须改另一处，否则 compare 找不到哨兵会退化成从头比。
- `CR_INIT_VALUE = 0x00004000`（复位默认值，避开 EALLOW）。

## 二、工具链 bug（2026-07-02，2000 条大用例暴露）

这两个 bug 与网络/对齐改动无关，是生成器和日志处理自身的问题，已修复。

### 1. `tool/tool.py:463` 移位越界

- **现象**：2000 条量级的生成几乎必失败，`randint` 报空区间。
- **真因**：`1 << (reg2_bits // randint(1,4))` 当 `randint` 取到 1 时变成 `1 << 32` 越界。
- **处置**：移位上限收敛到 `reg2_bits - 1`。

### 2. `script/log_process.py` trace 提前耗尽

- **现象**：`sys.exit(1)`，log_process 失败。
- **真因**：`log_level3` 只存 GR0–29 的写回（丢了 GR30/31 及 BAR/MR/OFF），而 boot 阶段 `gr_trace` 开头多出几行；经 forward-resync 跳过后尾部行数不足。
- **处置**：耗尽时优雅 `return`（保留已匹配的写回），并加 `reg <= 29` 过滤。2000 条验证 99.81% 对齐。

## 三、simv / harness 假象——"movig 芯片 bug"连环误判（2026-07-02/03）

**四次都不是芯片 bug。** 逐条记录，因为现象非常像真 bug：

| 现象 | 真因 |
|---|---|
| `movigh GR5` 读到 `0x0000`（期望非零） | RTL 已修但 simv 未重编，跑的是旧 RTL |
| `movigh GR17` 读到 `0x0b`（期望 `0xbc35b47b`） | 远程磁盘满 → `partitionlib` 损坏 → 坏 simv。删 partitionlib 全量重编后正确 |
| `movigl GR0` 读到 `0x0d`（期望 `0xdeadfb1f`） | simv 建于磁盘仅 ~1.5G 时崩溃，trace 被截断成 151 行、末尾生断出 `0xd`。磁盘恢复 62G 重编后正确 |
| `movigl GR28` 读到 `0` | `run_p65_test.sh` 轮询早取：原逻辑"trace 有行就算完成"，拉到仿真中途未写完的部分 trace（末行半截、行数远少于 ISS） |

**教训**：
- 只靠 mtime 判断 `SIMV_FRESH` 不够——磁盘满会**静默**产出坏 simv。
- 每次分析前必须确认：编译 `DONE_RC=0`、日志无 `corrupted` / `No space`、`df -h` 有余量。
- 值变成 `0x0d`、`0x0b` 这种"看起来像半个十六进制数"的残值，几乎必然是 trace 截断，不是芯片算错。

### 已修的轮询逻辑（2026-07-03）

完成判据改为：**进程退出(DONE) 且 trace 非空**，或 **trace 行数连续 3 次（约 45s）不再增长**。要求"连续 3 次"是因为仿真中途可能短暂（>15s）停写，`[100s]=455 [115s]=455` 这种单次相等会误判。修后用健全 simv 跑新随机用例 = 0 mismatch / 100%。

## 四、遗留未解问题

### ⚠️ 曾误判为"JTAG `$stop` 卡住覆盖率"——实为算错覆盖率（2026-07-21）

**结论先行：JTAG `$stop` 无害，测试每次都 100% 跑完。** 下面保留误判过程，因为这个坑很容易再踩。

**误判是怎么来的**：拿 `core0_gr_trace.dat` 的行数去比 `gr_trace_instr.txt` 的行数（1075 vs 1704 → "63%"），据此认定测试被截断，然后花了很久去查 JTAG。但**两个文件口径不同**：chip trace 每行都是一次写回，ISS trace 包含大量不产生写回的指令行。按真实写回数重算，四轮全是 **949/949、703/696、633/633、278/278 → 100%**。

**推翻误判的决定性实验**：把 TB 超时依次降到 100ms、80ms（都低于 123.5ms 的复位时刻，使仿真走 `$finish`/`$fclose` 正常结束），同一份镜像三次都得到**完全相同的 404 行**。既然 80ms 就已拿到全部数据，说明测试在 80ms 前就跑完了，后面那次复位和 `$stop` 都发生在测试完成之后。

**事件链的真实顺序**：测试跑完 → core0 空闲 → `core0_idle_line` 抬起 → `c2000_tb.v:100` 的 `always` 块延时 20ms → 触发后续动作 → core0 复位 → `c2000_jtag.v:4803` 的 reset-test `forever` 块醒来 → `id_test` 在复位期间读 IDCODE 得 `0xffffffff` → `:179 $stop`。**全是收尾现象。**

**教训**：日志里最显眼的结束事件（`$stop`/`STATUS: failed`）未必是问题所在——它只是最后发生的那件事。先确认"数据是否完整"，再去追"仿真为什么结束"。

---

以下为误判期间记录的现象，仅作参考：

- **当时的错误认知**：chip trace 明显短于 ISS（1075 vs 1704、829 vs 1285），以为约 60% 覆盖。日志尾部：

  ```
  (123838380 ns) Task c_goto_run_test_idle
  (123852780 ns) TEST: id_test
  (124529580 ns) STATUS: failed (Read ID = 0xffffffff, Expected ID = 0x20280801
  ucli%
  ```

- **直接原因**：`c2000_jtag.v:179` 的 `id_test` 读 IDCODE 失败就 `$stop`。
- **但 IDCODE 读不出只是"果"**：触发它的是 `c2000_jtag.v:4803` 那个 `forever` 块——

  ```verilog
  // for Reset Test, jtags_sram ENV mast reset at jtags debug finish
  forever begin
      @(posedge ~...cpu0_sysrsn);   // 等 core0 复位拉低
      @(posedge ...cpu0_sysrsn);    // 等复位释放
      goto_run_test_idle;
      id_test;                       // ← $stop 在这里
  ```

  它**只在 `cpu0_sysrsn` 翻转时才醒**。所以真正发生的是 **core0 在约 123.7ms 被复位了**，BFM 醒来时芯片仍在复位态，TAP 读回全 1。

- **当时排除过的解释**（现已知整件事无害，这些排除过程仍可参考）：
  - 不是自由运行的看门狗：BASE_PC 配错导致核挂死的那两轮跑到 400ms 完全没有复位。核不执行就不复位——现在知道原因是**核没跑完程序就不会进入空闲，也就不会触发那条收尾链**。
  - 不是随机 store 打到 core1 内存：`BANK_NUM` 24→20 把数据区收到 `0x9FFFF` 之后，复位仍在 123.66ms 发生。
  - 复位时刻在不同随机流下高度一致（123.660 / 123.838 / 124.164 ms）。

**实用结论**：把 TB 超时设在复位时刻之下（实测 **80ms** 对 1000~2000 条用例都够），仿真就走 `$finish`/`$fclose` 干净结束，完全不会碰到 JTAG `$stop`，日志也不会出现吓人的 `STATUS: failed`。这是当前推荐配置。

## 四·五、指令数超出执行窗口 → trace 出现 `0xxX`，compare.py 崩溃（2026-07-21）

- **现象**：`compare.py` 报 `Error: File format incorrect - invalid literal for int() with base 16: '0xxX'`，trace 末行是：

  ```
  0x1c    0x00032098    0x00004000     ← 正常执行中
  0xxX    0x00280000    0x00000000     ← 最后一行
  ```

- **解读**：`0xxX` 是 Verilog `$fwrite("0x%h")` 打印 **X（未知态）** 的结果，`0x280000` 是复位向量。**这是复位发生的瞬间被抓进了 trace** —— 复位期间寄存器写地址为 X。
- **真因**：芯片可用的执行窗口只有约 64 ms（boot 结束约 60 ms → 约 123.5 ms 的一次复位）。用例太长跑不完，复位就打在测试中途。
- **实测边界**：2000 / 5000 条能跑完；**10000 条不行**。
- **处置**：减少指令数（默认 5000）。这**不是芯片 bug**，也不是 trace 采集问题。
- **注意**：这与"核跑飞"要区分开——跑飞时 PC 会在中途切回 BOOT 区且**加大超时后 trace md5 不变**；本现象是全程在测试码区、只在最后一行被复位打断。

## 五、远程执行环境约束

- 远程登录 shell 是 **tcsh**。复杂命令必须走 `ssh lx5 bash -s <<'EOF' ... EOF` 管道；`ssh lx5 "bash -lc '...'"` 会被 tcsh 重新拆分参数而破坏。
- 从 Windows 侧发起统一包裹：`wsl.exe -u zhaotao -- bash -lc '...'`。
- `run_p65_test.sh` 里所有 `ssh` 都加了 `-T`（不分配伪终端），并在进入时 `stty sane`、退出时恢复。这是为了防止 ssh 子进程改坏本地终端的 `ONLCR` 换行模式导致输出阶梯错位、且残留到下次运行。改脚本时不要把这些去掉。
- 大日志（`result.txt`、`simulator.log` 等）先 Grep 定位再读小窗口，不要整读。

---
name: dsp-spyglass-lint
description: 手动触发的 QX DSP/MCU RTL SpyGlass lint 检查流程。用于用户明确要求使用 SpyGlass、spyglass、sg_shell 或 lint 检查指定 RTL 文件时；按用户指定文件在服务器 P65/025/034/039p/049/137/377/core 等项目上生成临时 SpyGlass project，运行 lint/lint_rtl，提取错误、警告和报告路径。
---

# DSP SpyGlass Lint

## 触发方式

仅在用户明确要求使用本 skill、SpyGlass、spyglass、sg_shell 或“跑 lint/静态检查”，并且指定要检查的 RTL 文件时使用。不要主动替代编译、仿真或 result.txt 分析流程。

另外，`dsp-kernel-auto-verification` 在准备提交 git 代码前，可以调用本 skill 作为强制 SpyGlass lint 门禁；此时检查范围应限定为本次准备提交的 RTL/相关设计文件。

## 执行环境（重要）

本机能连通远程服务器的网络与凭证（VPN、`~/.ssh/config`、免密密钥、别名 `lx5`）都在 **WSL**（发行版 `Ubuntu-22.04`，用户 `zhaotao`）里；Windows 上直接 `ssh` 连不通。因此**所有访问远程服务器的命令（ssh/scp）都必须在 WSL 内执行**：

- 先确保 WSL 内 VPN 已连：在 WSL 里执行 `qx-on`，并用 `wsl.exe -u zhaotao -- bash -lc "ip route get 10.18.30.200"` 确认路由走 `cnem_vnic`。
- 远程命令统一用别名 `lx5`（= `zhaotao@10.18.30.200`，已配好免密），并用 `wsl.exe` 包裹：
  - 执行远程命令：`wsl.exe -u zhaotao -- ssh lx5 "<远程shell命令>"`
  - 上传文件：`wsl.exe -u zhaotao -- scp <WSL路径> lx5:<远程路径>`。Windows 盘符路径在 WSL 中是 `/mnt/<盘符小写>/...`，例如本项目 `D:\workplace\QX_Workplace\p65` → `/mnt/d/workplace/QX_Workplace/p65`。
- 本地分析（`git status`、读取本地 RTL）仍在 Windows 正常进行。
- 注意多层引号链：PowerShell → wsl → ssh → 远程 bash。复杂远程脚本优先单引号包裹、分步执行或 here-doc 落到远程再运行。

## 远程环境

- 服务器：通过 WSL 访问，统一用别名 `ssh lx5`（= `zhaotao@10.18.30.200`）；调用方式见上方“执行环境”。
- 项目路径：`~/Desktop/{project}`，常用项目包括 `p65`、`025`、`034`、`039p`、`049`、`137`、`377`、`core`
- P65 实际路径通常为：`/home/zhaotao/Desktop/p65`
- SpyGlass 命令通常已在 PATH：
  - `spyglass`
  - `sg_shell`
  - `spyglass_lc`
- 常用 methodology：`$SPYGLASS_HOME/GuideWare/latest/block/rtl_handoff`
- 常用 goal：`lint/lint_rtl`

## 基本原则

1. 用户指定哪些文件，就围绕这些文件检查；不要默认全工程跑很久。
2. 临时工程、日志和报告放到远程项目的 `agent/spyglass_<短任务名>/` 或 `rtl/<临时工程名>/` 下。
3. 不要修改最终 RTL 来适配 SpyGlass。需要补充 prj、脚本、临时 wrapper 时，只放在 `agent/` 下。
4. 如果使用已有工程 prj，要说明它可能包含旧的 blackbox 或范围外 warning；必要时再做一个“指定文件模块级 prj”来判断本次修改是否新增问题。
5. 输出时区分：
   - SpyGlass 命令是否成功运行
   - Design Read/Blackbox 是否干净
   - `lint/lint_rtl` 的 error/warning 总数
   - 是否有消息落在用户指定文件或修改行附近
   - 结论属于“历史工程问题”、“本次修改相关问题”还是“证据不足”

## 推荐流程

> 下文 `bash` 代码块里的命令都是**在远程服务器上执行**的内容。实际调用时必须通过 WSL 包裹：单条用 `wsl.exe -u zhaotao -- ssh lx5 "<命令>"`；多步/含 here-doc 的脚本，建议先用 here-doc 把脚本写到远程（`wsl.exe -u zhaotao -- ssh lx5 "cat > ~/agent/run.sh <<'EOF' ... EOF"`）再 `ssh lx5 "bash ~/agent/run.sh"`，避免多层引号被吞。本地 `git status` 等仍在 Windows 执行。

### 1. 确认文件和项目

先确认用户指定文件在本地和远程的对应路径。本地 `git status` 在 Windows 跑，远程命令通过 WSL 包裹。例如 P65：

```powershell
git status --short
wsl.exe -u zhaotao -- ssh lx5 "cd /home/zhaotao/Desktop/p65 && ls -l rtl/swift_core/core_ex2_fvcu_s0.v"
```

如果本地 RTL 已修改但远程未同步，先用 `scp`（在 WSL 内、走别名 `lx5`）同步指定文件。Windows 盘符路径在 WSL 中为 `/mnt/<盘符小写>/...`：

```powershell
wsl.exe -u zhaotao -- scp /mnt/d/workplace/QX_Workplace/p65/rtl/swift_core/core_ex2_fvcu_s0.v lx5:~/Desktop/p65/rtl/swift_core/core_ex2_fvcu_s0.v
```

从 Windows 上传后，若远程 diff 出现整文件行尾变化，在远程转回 LF：

```bash
perl -0pi -e 's/\r\n/\n/g' rtl/swift_core/core_ex2_fvcu_s0.v
```

### 2. 优先查找已有 SpyGlass 工程

在远程项目根目录查找现成 prj/sgdc/报告：

```bash
cd /home/zhaotao/Desktop/p65
find . -maxdepth 5 \( -iname '*spyglass*' -o -iname '*.sgdc' -o -iname '*.prj' \) -print
```

常见 P65 示例：

- `rtl/fpu.prj`：FPU/FVCU 相关工程，top 常为 `core_fpu`
- `rtl/zt.prj`：另一个 FPU 子集示例

用已有工程前先看 goal 是否存在：

```bash
cd /home/zhaotao/Desktop/p65/rtl
spyglass -project fpu.prj -batch -showgoals > ../agent/spyglass_task/showgoals.log 2>&1
grep -n 'lint/lint_rtl' ../agent/spyglass_task/showgoals.log
```

### 3. 运行工程级 lint

如果已有 prj 覆盖用户指定文件，复制成临时 prj 后运行，避免污染原工程文件：

```bash
cd /home/zhaotao/Desktop/p65
mkdir -p agent/spyglass_task
cp rtl/fpu.prj agent/spyglass_task/fpu_task.prj
cd rtl
spyglass -project ../agent/spyglass_task/fpu_task.prj -batch -goals 'lint/lint_rtl' \
  > ../agent/spyglass_task/lint_run.log 2>&1
```

提取摘要：

```bash
tail -100 ../agent/spyglass_task/lint_run.log
grep -R -n '用户指定文件名\|关键新增符号' fpu_task*/consolidated_reports fpu_task*/core_*/lint/lint_rtl/spyglass_reports 2>/dev/null
```

如果出现 blackbox 且原因是 prj 缺依赖文件，优先在临时 prj 里补依赖。例如 `core_ex2_fvcu_s0.v` 需要 `core_fvcu_rounding.v`：

```bash
awk '1; /read_file -type verilog swift_core\/core_ex2_fvcu_s0.v/ {print "read_file -type verilog swift_core/core_fvcu_rounding.v"}' \
  rtl/fpu.prj > agent/spyglass_task/fpu_task_with_dep.prj
```

### 4. 指定文件模块级 lint

当工程级 prj 报很多范围外问题，或者用户只关心指定文件，生成模块级 prj。示例：

如果工程级 prj 存在历史 blackbox、缺依赖或大量范围外 warning，不能直接把这些问题归因到本次修改；应继续构造指定文件相关的模块级最小 prj，或者在报告中明确说明无法隔离的原因。

```bash
cd /home/zhaotao/Desktop/p65
mkdir -p agent/spyglass_task/module_only
cat > agent/spyglass_task/module_only/core_ex2_fvcu.prj <<'EOF'
#!SPYGLASS_PROJECT_FILE
#!VERSION 3.0
read_file -type verilog ../include/core_define.v
read_file -type verilog swift_core/core_fvcu_rounding.v
read_file -type verilog swift_core/core_ex2_fvcu_s0.v
set_option projectwdir .
set_option language_mode mixed
set_option designread_enable_synthesis no
set_option designread_disable_flatten no
set_option active_methodology $SPYGLASS_HOME/GuideWare/latest/block/rtl_handoff
set_option top core_ex2_fvcu_s0
current_methodology $SPYGLASS_HOME/GuideWare/latest/block/rtl_handoff
EOF

cd rtl
spyglass -project ../agent/spyglass_task/module_only/core_ex2_fvcu.prj \
  -batch -goals 'lint/lint_rtl' \
  > ../agent/spyglass_task/module_only/lint.log 2>&1
```

读取报告：

```bash
tail -100 ../agent/spyglass_task/module_only/lint.log
find . -path '*consolidated_reports*lint_lint_rtl/moresimple.rpt' -print
sed -n '1,160p' <moresimple.rpt>
```

### 5. 汇报格式

最终用简短结构汇报：

```text
SpyGlass 检查范围：
- 项目：p65
- 文件：rtl/swift_core/core_ex2_fvcu_s0.v
- goal：lint/lint_rtl
- prj：<临时 prj 路径>

结果：
- Command-line read：x error, y warning
- Design Read：x error, y warning
- Blackbox Resolution：x error, y warning
- SGDC Checks：x error, y warning
- Policy lint：x error, y warning
- Policy morelint：x error, y warning
- Total：x error, y warning, z info

涉及指定文件的消息：
- <rule> <severity> <file:line> <message>

判断：
- 是否有 fatal/error
- 是否有与本次修改直接相关的 warning
- 若剩余问题来自旧工程范围或缺依赖，要明确说明

归因结论：
- 历史工程问题：<是/否，依据>
- 本次修改相关问题：<是/否，依据>
- 证据不足：<是/否，缺什么证据>

报告路径：
- <moresimple.rpt>
- <spyglass.log>
- <goals_summary.html>
```

## 注意事项

- `spyglass` 有时返回 exit code 0 但结果里有 error/warning；必须读 Results Summary。
- 旧工程 prj 可能缺子模块依赖，导致 `ErrorAnalyzeBBox` / blackbox；这不一定是本次修改引入。
- 模块级 prj 更适合判断“指定文件是否新增 lint 问题”，工程级 prj 更适合看集成上下文。
- 不要把临时 SpyGlass prj、报告、HTML 加入 RTL commit，除非用户明确要求。

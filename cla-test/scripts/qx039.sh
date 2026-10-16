#!/bin/bash
# WSL 远程辅助脚本模板（039，host 10.18.30.199 经 WSL VPN）。
# 用途：绕开 ~/.ssh/config 的 10.18.30.* 通配规则（那是给内网 git 服务器 .198 的密钥+代理规则，
# 会误捕 .199），用命令行 -o 覆盖为 zhaotao 直连。
#
# 认证凭据处理（标准安全习惯）：不把密码写进命令行参数。用 sshpass 从一个 600 权限文件读取；
# 该文件由 python 从 config_039.json 生成一次即可（见下）。也可改用 SSH 密钥认证，若服务器已装公钥。
#
# 用法（用 PowerShell 调，避免 git-bash 改写 /mnt 路径）：
#   wsl -u zhaotao -- bash /mnt/d/workplace/QX_Workplace/cla_bg_039/agent/qx039.sh survey
#   wsl -u zhaotao -- bash .../qx039.sh ssh '<远端命令>'
#   wsl -u zhaotao -- bash .../qx039.sh scp_to  <本地/mnt路径> <远端相对home路径>
#   wsl -u zhaotao -- bash .../qx039.sh scp_from <远端路径> <本地/mnt路径>
#   wsl -u zhaotao -- bash .../qx039.sh runfile  <本地bash脚本>   # 喂给远端 bash，避开 csh

CFG=/mnt/d/workplace/QX_Workplace/cla_bg_039/config_039.json
PASSFILE=$HOME/.qxpass039
HOST=10.18.30.199

# 首次生成密码文件（若不存在）：从 config 读取，600 权限，不回显
if [ ! -s "$PASSFILE" ]; then
  python3 -c "import json;print(json.load(open('$CFG'))['ssh']['password'])" > "$PASSFILE"
  chmod 600 "$PASSFILE"
fi

SSHOPT="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=25 -o User=zhaotao -o ProxyCommand=none -o PubkeyAuthentication=no -o PasswordAuthentication=yes -o PreferredAuthentications=password -o NumberOfPasswordPrompts=1"
qx_ssh() { sshpass -f "$PASSFILE" ssh $SSHOPT "$HOST" "$@"; }
qx_scp() { sshpass -f "$PASSFILE" scp $SSHOPT "$@"; }

case "$1" in
  survey)
    qx_ssh 'hostname; ls -d ~/Desktop/039/vcs; ls -la ~/Desktop/039/vcs/simv ~/Desktop/039/vcs/simv_verdi ~/Desktop/039/vcs/Makefile' ;;
  ssh)      shift; qx_ssh "$@" ;;
  scp_to)   qx_scp "$2" "${HOST}:$3" ;;
  scp_from) qx_scp "${HOST}:$2" "$3" ;;
  runfile)  sshpass -f "$PASSFILE" ssh $SSHOPT "$HOST" bash -s < "$2" ;;
  *) echo "usage: qx039.sh {survey|ssh <cmd>|scp_to <local> <remote>|scp_from <remote> <local>|runfile <script>}" ;;
esac

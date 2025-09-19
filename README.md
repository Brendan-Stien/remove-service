## 🔹 脚本名称
remove-service.sh

## 🔹 功能目标
一个 **安全卸载 systemd 服务** 的脚本。  
相比手动删除 `.service` 文件更安全，支持 **备份、日志、Dry-run、确认提示**，避免误删关键服务。

## 📥 安装

```bash
wget --no-check-certificate -qO remove-service.sh 'https://raw.githubusercontent.com/Brendan-Stien/remove-service/main/remove-service.sh'
```
` less remove-service.sh `

` bash remove-service.sh `

- 提供备份机制（unit 文件、drop-in 配置、timer、可执行文件）
- 日志记录所有操作，方便回溯
- 提供 Dry-Run 模式，先看清楚要做什么再执行
- 在可能由系统包管理器安装的服务时 强烈提示，避免误删系统服务

📝 示例

查看卸载计划：
```bash
sudo ./remove-service.sh --dry-run nginx
```

安全卸载 serverstatus 服务：
```bash
sudo ./remove-service.sh serverstatus
```

无需交互，强制卸载：
```bash
sudo ./remove-service.sh -y --force serverstatus
```

# 核心功能
## 停用服务

- 停止正在运行的服务
- 禁止开机启动
- 临时 mask 服务，避免执行过程中被 systemd 重新拉起
## 备份 & 移动文件

- 自动备份 unit 文件 (.service)、timer (.timer)、drop-in 配置目录 (*.d)
- 备份位置默认为 /var/backups/remove-service/<service>-<timestamp>/
- 不直接删除，而是 移动到备份目录

## 日志记录

- 所有操作写入日志 /var/log/remove-service-<service>-<timestamp>.log
- 如果 /var/log 不可写，则退回 /tmp


## 安全检查

- 检测 unit 是否来自 /lib/systemd/system 或 /usr/lib/systemd/system → 可能是 包管理器安装的服务，会提示警告
- 如果不是 --force 模式，需要用户确认才能继续

## 高级选项

--dry-run：只显示将要执行的操作，不真正修改

--yes/-y：跳过交互确认（自动确认 yes）

--backup-dir=PATH：自定义备份目录

--remove-files：尝试删除服务的可执行文件（来自 ExecStart，默认关闭，非常危险）

--remove-timers：同时处理同名 .timer

--force：即使 unit 来自包管理器目录也继续执行

--verbose：输出更详细的信息

## 系统刷新

- 执行 systemctl daemon-reload 和 systemctl reset-failed
- 清理残留 unit 状态

## 🛠️兼容性

适用于大多数 systemd 系统：Debian/Ubuntu、CentOS/RHEL、RockyLinux、Fedora、ArchLinux 等。

需要 bash 和 root 权限。

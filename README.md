# oracle-snatch 一键部署脚本

交互式安装器：在一台已有的 Ubuntu/Debian 机器上部署
[oracle-snatch](https://github.com/lucasforster1108-boop/oracle-snatch)，
自动重试创建 Oracle Always Free 的 VM.Standard.A1.Flex 实例（抢东京/新加坡等 home region 的免费 A1）。

和 trojan 一键脚本同样的体验：**需要你输入的地方会停下来问你，其余全自动。**

## 你只需要输入这些

| 步骤 | 输入 | 从哪拿 |
|---|---|---|
| 区域 | 选单（东京 / 新加坡 / 手输） | 目标租户的 home region |
| 实例参数 | 台数、核数、内存、盘、前缀（都有默认值，回车即过） | 默认 2 台 × 1 核 / 6 GB / 50 GB |
| API 凭据 | 二选一：① 本机生成密钥对，只把公钥粘到控制台，再填 user / tenancy 两个 OCID（fingerprint 脚本自动算）；② 粘贴控制台下载的私钥 + 预览里的三个值 | OCI 控制台 → 用户设置 → API 密钥 |
| 子网 OCID | 粘贴 | 控制台 → 任意同区域实例 → 子网 → OCID |
| Telegram | token + chat id（可跳过） | 你自己的 bot |

脚本自动完成：装 python3-venv 与 oci SDK、生成新机登录密钥、从上游拉取 snatch.py 并
**校验 md5（255234e40d2308024d7c320fd6464dc4，与人工审过的版本一致才继续）**、
写 config.env 与 systemd 服务、dry-run 验证、启动第一台的抢机服务、发 Telegram 测试通知。

## 放到 GitHub

脚本不含任何密钥（凭据都是运行时输入、只写进目标机本机），仓库可以设为 **Public**，
这样 raw 拉取不需要令牌。

1. 打开 github.com → New repository → 名字如 `oracle-snatch-deploy` → Public → Create
2. 在仓库页点 **uploading an existing file**，把 `install-oracle-snatch.sh` 和本 README 传上去，Commit
3. 以后在任何目标机上（root 身份）两条命令搞定：

```bash
curl -sL -o install-oracle-snatch.sh https://raw.githubusercontent.com/<你的用户名>/oracle-snatch-deploy/main/install-oracle-snatch.sh
bash install-oracle-snatch.sh
```

## 部署之后

```bash
systemctl is-active oracle-snatch-1                 # 还在抢吗
journalctl -u oracle-snatch-1 -n 5 --no-pager       # 最近几次尝试
cat /root/oracle-snatch-1/snatched.json             # 出现 IP = 抢到了
```

- 第一台到手后开第二台：
  `cp /root/oracle-snatch-2.service /etc/systemd/system/ && systemctl daemon-reload && systemctl enable --now oracle-snatch-2`
- SSH 可以随时关，服务在目标机上自己跑，重启自启。
- 不要改小重试间隔（120 秒 / 限流 300 秒已是脚本内的安全值）。
- A1 免费机闲置 7 天（CPU/网络/内存 95 分位 <20%）会被 Oracle 回收，抢到尽快部署使用。
- 登录新机：用户 `ubuntu`，密钥就是部署机上的 `/root/.ssh/a1_key`，记得拷一份回自己电脑。
- dry-run 报错就停下：401 多半是 user/fingerprint/tenancy 填错或和私钥不对版；
  InvalidParameter 多半是启动盘小于 50 GB。

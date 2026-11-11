# 葫芦 · 服务器面板

一条命令完成安装，在浏览器里管理网站、证书、数据库、备份与安全防护。

官网与完整说明：<https://etng.github.io/hyotan-release/>

## 快速安装

在服务器上执行：

```bash
curl -fsSL https://etng.github.io/hyotan-release/install.sh | sudo bash
```

安装程序会自动识别系统架构、核对安装包完整性，完成后启动服务，并在屏幕上打印访问地址与初始账号。

## 适用环境

- 64 位 Linux 服务器，系统使用 systemd（如 Ubuntu、Debian）
- 建议内存 2 GB 以上
- 提供 x86_64 与 ARM64 两种安装包

## 安装之后

1. 用浏览器打开屏幕上打印的访问地址，使用初始账号登录。
2. 登录后立刻修改初始密码，并绑定两步验证。
3. 在云服务器防火墙里只放行面板使用的端口。

忘记了访问地址，可在服务器上执行 `hyotan entry show` 重新查看。

## 版本下载

所有安装包与校验值都在「版本下载」页：<https://github.com/etng/hyotan-release/releases>

也可以先下载安装包，再在服务器上离线安装：

```bash
./install.sh --from hyotan-linux-amd64
```

## 升级

在面板的「关于」页检查更新并确认安装即可。升级前会自动保留一份可回退的旧版本。

## 问题反馈

遇到问题时，请到「问题反馈」里描述现象，并附上系统版本与面板提示信息：
<https://github.com/etng/hyotan-release/issues>

## 许可

开放源代码，遵循 AGPL-3.0 许可。

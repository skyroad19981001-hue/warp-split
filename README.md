Gemini-WARP-Guard: 极致自愈分流方案
​项目简介：
本方案专为解决VPS 访问 Gemini、BitMart 等服务时的地区限制与连接不稳问题。结合了 WARP 隧道、Redsocks 转发以及 AI 级联强化的守护脚本。
​核心黑科技：
​动态域解析：实时嗅探 Gemini/BitMart 域名 IP 变化，自动更新 ipset 名单，告别手动维护。
​三重自愈逻辑：监控网卡状态、服务进程及业务连通性。只要 gemini.google.com连不上，脚本 60 秒内“暴力拉回”。
​流量精准剥离：原生 IP 跑普通流量，WARP 隧道跑特定流量，速度与解锁兼得。
​适用人群：
​在“不支持地区”死磕 Gemini 的硬核玩家。
​对交易环境稳定性要求极高的 BitMart 交易员。
​像我一样“不甘心”被 VPS 搞定的折腾家。
---

## 特性

- ✅ 精准分流：Gemini + BitMart → WARP，其余 → 原生 IP
- ✅ 动态 IP 更新：每 6 小时自动重新解析域名，更新 iptables 规则
- ✅ 自动守护：每 60 秒检测连通性，断线自动重连
- ✅ 开机自启：systemd 管理，重启后自动恢复所有规则
- ✅ 交互菜单：安装 / 卸载 / 状态查看 / 日志查看

---

## 支持系统

| 系统 | 版本 |
|------|------|
| Ubuntu | 18.04 + |
| Debian | 10 + |
| CentOS | 7 + |
| Rocky Linux | 8 + |
| AlmaLinux | 8 + |

---

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/skyroad19981001-hue/warp-split/main/warp-split.sh)
```

运行后选择 `1` 安装即可。

---

## 流量走向

```
Gemini 流量
    │
    ▼
iptables WARP_GOOGLE 链
    │
    ▼
redsocks (127.0.0.1:12345)
    │
    ▼
WARP SOCKS5 (127.0.0.1:40000)
    │
    ▼
Cloudflare WARP → Google Gemini ✅

BitMart 流量  ──────────────────────────── 同上路径 ✅

其他所有流量 ──────────────────────────── 原生 IP 直连 ✅
```

---

## 常用命令

```bash
# 查看守护进程状态
systemctl status warp-split

# 查看运行日志（最近 50 行）
tail -50 /var/log/warp_guard.log

# 查看当前分流规则
iptables -t nat -L WARP_GOOGLE -n

# 查看 WARP 连接状态
warp-cli status

# 手动重启守护进程
systemctl restart warp-split
```

---

## 卸载

运行脚本后选择 `2` 卸载，将完整移除：

- Cloudflare WARP 客户端
- redsocks
- iptables 规则
- systemd 服务
- 守护脚本

---

## 原理

1. **redsocks** 监听本地 12345 端口，将 TCP 流量转发至 WARP SOCKS5（40000 端口）
2. **iptables** OUTPUT 链拦截目标 IP，重定向至 redsocks
3. **守护脚本** 每 60s 检测 Gemini 连通性，失败则自动重连；每 6h 重新 DNS 解析更新目标 IP
4. **systemd** 保证守护脚本开机自启、崩溃自动重启

---

## 添加更多分流域名

编辑 `/root/warp_guard.sh`，在 `update_ips()` 函数中添加新域名解析：

```bash
# 示例：添加 OpenAI
OPENAI_IPS=$(dig +short api.openai.com | grep -E '^[0-9]+\.')
for ip in $OPENAI_IPS; do
    iptables -t nat -A WARP_GOOGLE -p tcp -d "$ip" -j REDIRECT --to-ports 12345
done
```

然后重启守护进程：

```bash
systemctl restart warp-split
```

---

## License

MIT © skyroad1998 & Claude (Anthropic)

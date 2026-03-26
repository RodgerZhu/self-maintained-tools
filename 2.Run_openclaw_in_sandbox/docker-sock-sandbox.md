# Docker Socket 与 Sandbox 模式详解

> 适用版本：based on `scripts/docker/setup.sh` 分析，March 2026

---

## 1. 背景：为什么 gateway 容器会用到 docker.sock？

OpenClaw gateway 运行在容器内时，如果需要让 AI 在**隔离环境**中执行工具（文件读写、exec 命令、代码执行等），就必须能够创建新的容器来承载这些操作。容器内进程与宿主机 Docker daemon 通信的唯一方式，就是通过 **Unix socket：`/var/run/docker.sock`**。

---

## 2. 整体架构（DooD：Docker-outside-of-Docker）

```
宿主机
├── Docker daemon (/var/run/docker.sock)
│       ↑ bind mount（socket 挂入 gateway 容器）
│
├── openclaw-gateway 容器
│   ├── gateway 进程（持有 socket 完整访问权）
│   └── AI 工具调用 ──► 通过 daemon 创建兄弟容器
│                                │
└── openclaw-sandbox 容器 ◄───────┘
    （兄弟容器，无 socket，无特权）
    └── skill / exec / 文件操作 在此隔离运行
```

这种模式称为 **DooD（Docker-outside-of-Docker）**，与 DinD（Docker-in-Docker）的区别：

| | DooD | DinD |
|---|---|---|
| 原理 | 共享宿主机 daemon | 容器内运行独立 Docker daemon |
| 特权模式 | 不需要 | 需要 `--privileged` |
| 兄弟/子容器 | 兄弟容器（同层级） | 子容器（嵌套） |
| 风险 | socket 等价 root | 更高，完全特权 |

---

## 3. docker.sock 的风险本质

> **挂入 docker.sock = 赋予容器等同宿主机 root 的能力**

任何持有 `/var/run/docker.sock` 的进程可以：
- 创建/删除任意容器
- 将宿主机任意目录挂入新容器并读写
- 通过容器逃逸到宿主机文件系统

这个风险由**你对 gateway 软件本身的信任**来承担，sandbox 模式无法消除它。

---

## 4. Sandbox 模式的真正目的

Sandbox 模式保护的目标是：**宿主机文件系统和进程不被 AI 工具调用误操作（或恶意操作）**。

```
不开 sandbox（默认）：
  AI 工具调用 → 直接在 gateway 进程内执行 → 可读写宿主机挂载目录

开启 sandbox：
  AI 工具调用 → 放入沙箱容器执行 → 文件操作限制在容器内，不直接触碰宿主机
```

**sandbox 保护的是 AI 执行的内容，不是 socket 本身。**

---

## 5. 信任边界示意

```
宿主机
│
├── /var/run/docker.sock ◄── bind mount（挂入 gateway 容器）
│
├── openclaw-gateway 容器 ─────────────────── [信任区域]
│   │
│   ├── gateway 进程
│   │     └── 持有 socket 完整访问权，可向 daemon 发任意指令
│   │
│   └── AI 工具调用请求
│               │
│               │ 向 Docker daemon 发指令创建兄弟容器
│               ▼
└── openclaw-sandbox 容器 ────────────────── [不信任区域]
    │
    ├── 无 docker.sock
    ├── 无特权
    ├── AI 生成的代码在此执行
    └── workspaceAccess=none 时不挂载用户项目文件
```

---

## 6. setup.sh 的 5 层防护检查

`OPENCLAW_SANDBOX=1` 并不直接挂 socket，而是经过严格的前置检查：

```
① OPENCLAW_SANDBOX=1 是否设置？
      否 → 跳过，不挂 socket（最安全默认值）
      是 ↓

② 镜像内是否有 Docker CLI？
      否 → 警告 + 跳过（有 CLI 才能通过 socket 操作 Docker）
      是 ↓

③ /var/run/docker.sock 文件是否存在？
      否 → 警告 + 跳过
      是 ↓

④ 三项 sandbox 配置是否全部写入成功？
      （mode / scope / workspaceAccess）
      否 → 回滚 mode=off + 删除 overlay + 重建 gateway（不带 socket）
      ⚠️  防止 socket 暴露而 sandbox 策略不完整
      是 ↓

⑤ 重新 up gateway（加载 sandbox overlay，携带 socket 挂载）
```

---

## 7. Sandbox 的三个配置维度

| 配置项 | 含义 | setup.sh 默认写入 |
|---|---|---|
| `agents.defaults.sandbox.mode` | 何时启用沙箱 | `non-main`（仅非主会话） |
| `agents.defaults.sandbox.scope` | 容器粒度 | `agent`（同一 agent 的会话共用一个容器） |
| `agents.defaults.sandbox.workspaceAccess` | 工作区访问权 | `none`（完全隔离，不挂载项目文件） |

**`non-main` 的含义：**  
主聊天会话（session key = `"main"`）仍在 gateway 进程内运行；群聊/频道/子任务等非主会话放入沙箱。这是流畅性与安全性的权衡。

---

## 8. group_add 是做什么的？

```yaml
group_add:
  - "999"   # 宿主机 docker 组的 GID
```

`/var/run/docker.sock` 在宿主机属于 `docker` 组（GID 各系统不同）。  
gateway 容器内的 `node` 用户默认不在该组，无法读写 socket。  
`group_add` 将容器内 `node` 用户临时加入该 GID 对应的组，赋予 socket 访问权。  
setup.sh 会用 `stat -c '%g' /var/run/docker.sock` 动态探测真实 GID，避免硬编码失效。

---

## 9. 决策树：我应该挂 docker.sock 吗？

```
是否需要 AI 在容器内执行代码/命令/工具？
├── 否 ──────────────────────────────► 不挂 docker.sock（最安全状态）
│
└── 是
    │
    是否信任 gateway 软件本身？
    ├── 否 ──────────────────────► 此方案不适合（根本信任缺失）
    │
    └── 是
        │
        设置 OPENCLAW_SANDBOX=1
        让 setup.sh 自动完成检查和配置
        │
        └──────────────────────► 挂 socket + sandbox 隔离 AI 执行
```

---

## 10. 安全边界总结

| 能防止 | 不能防止 |
|---|---|
| AI 工具写操作污染宿主机文件 | gateway 进程本身对 socket 的完整访问 |
| AI 执行的进程影响 gateway 进程 | 宿主机 root 级别的 socket 风险 |
| 工具调用访问用户项目文件（`workspaceAccess=none`） | gateway 软件本身的漏洞利用 |
| AI 启动的进程访问 Docker daemon | elevated 工具调用（在宿主机执行，绕过沙箱） |

> 官方文档原话（[sandboxing.md](gateway/sandboxing.md)）：  
> *"This is not a perfect security boundary, but it materially limits filesystem and process access when the model does something dumb."*

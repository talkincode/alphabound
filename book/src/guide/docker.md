# Docker 与 GHCR 发布

设计默认生产形态仍是 **Azure VM + systemd 裸二进制**。Docker 镜像用于：

- 可复现的 **release 分发**（GHCR）
- 本地 / CI **shadow 实验室**
- 多架构（`linux/amd64`（arm64 可后续加回））预构建

**不是**「上了 Docker 就等于生产就绪」——真钱闸门见 [路线图](../planning/roadmap.md)。

## 镜像

| | |
|---|---|
| 仓库 | `ghcr.io/talkincode/alphabound` |
| 默认标签 | 仅 **git tag `v*`** 发布：`X.Y.Z`、`X.Y`、`latest`、`sha-<short>` |
| 用户 | uid `10001` `alphabound`（非 root） |
| 配置 | 镜像内 `/etc/alphabound/alphabound.toml`（`config/docker.toml`） |
| 数据卷 | `/var/lib/alphabound`（SQLite） |
| Web | 容器内 `0.0.0.0:8080`；**宿主机务必只映射 127.0.0.1** |

### 拉取

```bash
# 公共包可直接拉；若包仍是 private，先登录
echo $GHCR_TOKEN | docker login ghcr.io -u USERNAME --password-stdin

docker pull ghcr.io/talkincode/alphabound:0.1.0   # 推荐：与 git tag v0.1.0 对应
docker pull ghcr.io/talkincode/alphabound:latest  # 最近一次 v* 发布
```

首次 push 后若组织默认 private package，在 GitHub → Packages → alphabound → Package settings → **Change visibility → Public**（或保持 private 仅 CI/内部拉）。

### 运行（shadow）

```bash
docker run --rm \
  --name alphabound \
  -p 127.0.0.1:8080:8080 \
  -v alphabound-data:/var/lib/alphabound \
  ghcr.io/talkincode/alphabound:latest

curl -sS http://127.0.0.1:8080/health/live
open http://127.0.0.1:8080/
```

自检：

```bash
docker run --rm ghcr.io/talkincode/alphabound:latest \
  --config /etc/alphabound/alphabound.toml --self-check
```

### Compose

```bash
docker compose up --build          # 本地构建
IMAGE=ghcr.io/talkincode/alphabound:latest docker compose up
```

`docker-compose.yml` 已写死 `127.0.0.1:8080:8080`。

### 自定义配置

```bash
docker run --rm -p 127.0.0.1:8080:8080 \
  -v "$PWD/my.toml:/etc/alphabound/alphabound.toml:ro" \
  -v alphabound-data:/var/lib/alphabound \
  ghcr.io/talkincode/alphabound:latest
```

`[web] bind` 在容器内应为 `0.0.0.0:<port>`，否则 port-publish 进不来。配置解析**拒绝**任意公网 IP 绑定，只允许 `127.0.0.1` 与 `0.0.0.0`。

## CI 发布

工作流：[`.github/workflows/release-docker.yml`](https://github.com/talkincode/alphabound/blob/main/.github/workflows/release-docker.yml)

| 触发 | 行为 |
|---|---|
| push `main` | **不**构建镜像（只跑 [CI](../dev/build.md) 编译/测试） |
| push tag `v*` | 构建并推送 `X.Y.Z`、`X.Y`、`latest`、`sha-*` |
| `workflow_dispatch` | 手动；可附额外 tag（无 semver 时主要靠 `tag_extra` / sha） |

使用 `docker/build-push-action` + Buildx，`linux/amd64`，GHA cache，provenance/SBOM 开启。权限：`packages: write`（`GITHUB_TOKEN`）。

构建上下文必须包含 `prompts/`（嵌入二进制）；`.dockerignore` 不得排除 `prompts/**`。

### 打版本 release

```bash
git tag -a v0.1.0 -m "alphabound v0.1.0"
git push origin v0.1.0
# Actions → Release Docker → ghcr.io/talkincode/alphabound:0.1.0 等
```

## 本地构建

```bash
docker build -t alphabound:local .
docker run --rm -p 127.0.0.1:8080:8080 alphabound:local --ticks 3
```

需要 Docker Buildx（多架构时）与出网下载 Zig 0.16.0。

## 安全注意

1. **不要**把 `secrets.env` 打进镜像层；用 runtime 挂载 / orchestrator secret。
2. 宿主机端口只绑 `127.0.0.1`；远程用 SSH tunnel。
3. 镜像默认 `mode = shadow`，无交易密钥也跑得起来。
4. 容器 ≠ 过 Gate 3；Demo/Live 仍走验收矩阵。

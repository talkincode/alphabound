# 鉴权与 Analytics MCP

Dashboard / API 可选用 **Token + Session + Passkey** 保护数据面；外部 Agent 通过 MCP 拉取同一批 HTTP API，并可用 `submit_intel` 转发**已签名**的情报信封。控制面（pause / flatten / 下单）**永远不走** HTTP 或 MCP。

详细技术说明与仓库文件同步：

{{#include ../../../docs/DASHBOARD_AUTH_MCP.md}}

## 快速启用

```bash
# secrets.env（chmod 600）
ALPHABOUND_API_TOKEN=$(openssl rand -hex 32)
# 浏览器打开的 origin（本机）
ALPHABOUND_WEBAUTHN_RP_ID=localhost
ALPHABOUND_WEBAUTHN_ORIGIN=http://127.0.0.1:18180
```

重启 daemon 后：

```bash
curl -sS http://127.0.0.1:18180/api/v1/auth/status
# auth_required=true 时数据 API 需 token/session
```

## MCP

IDE / Copilot 用 `npx -y` **自动安装**，不必先 clone：

```json
{
  "mcpServers": {
    "alphabound": {
      "command": "npx",
      "args": ["-y", "alphabound-mcp"],
      "env": {
        "ALPHABOUND_API_BASE": "http://127.0.0.1:18180",
        "ALPHABOUND_API_TOKEN": "YOUR_TOKEN"
      }
    }
  }
}
```

```bash
npx -y alphabound-mcp install --client copilot
# 尚未发布到 npm 时：--source github
# 本仓库源码：node tools/alphabound-mcp/src/index.js install --source local --client copilot
```

从源码跑 stdio / HTTP / CLI（token 走环境变量）：

```bash
cd tools/alphabound-mcp
npm install
export ALPHABOUND_API_BASE=http://127.0.0.1:18180
export ALPHABOUND_API_TOKEN=YOUR_TOKEN   # 与 daemon 相同
npx alphabound-mcp                      # stdio，给 IDE
npx alphabound-mcp tools                # 列出全部 MCP 工具
npx alphabound-mcp get_system           # CLI 调用同一工具面
# 或本机 HTTP 网关：
# npx alphabound-mcp --http
```

工具列表见 [`tools/alphabound-mcp/README.md`](https://github.com/talkincode/alphabound/blob/main/tools/alphabound-mcp/README.md)。  
规划背景：[AGENT_ANALYTICS_MCP_PLAN.md](https://github.com/talkincode/alphabound/blob/main/docs/AGENT_ANALYTICS_MCP_PLAN.md)。

## 远程 HTTP + OAuth

Claude、ChatGPT、Cursor、VS Code 等支持远程 MCP 的客户端，用 URL 接入即可，不必持有 token。网关同时是资源服务器和一个**单 operator 授权服务器**：首次连接时客户端把浏览器带到网关的授权页，你输入 `ALPHABOUND_API_TOKEN` 批准该客户端（授权页会显示客户端自报名称和**批准后浏览器将跳转到哪里**，只批准你刚刚自己发起的连接）。

```bash
export ALPHABOUND_API_BASE=http://127.0.0.1:18180
export ALPHABOUND_API_TOKEN=YOUR_TOKEN                 # 长随机；同时是批准客户端的口令
export ALPHABOUND_MCP_OAUTH=1
export ALPHABOUND_MCP_PUBLIC_URL=https://mcp.example.com   # 客户端实际访问的 origin（无路径）
export ALPHABOUND_MCP_OAUTH_STATE_FILE=/var/lib/alphabound-mcp/oauth.json  # 重启后保持登录
export ALPHABOUND_MCP_TRUST_PROXY=1                    # 前面有一层 nginx
npx -y alphabound-mcp --http                           # 默认只监听 127.0.0.1:8723
```

- TLS 由反向代理终结，网关独占一个域名：见 `deploy/nginx-alphabound-mcp.conf.example`。
- 客户端接入地址是 `https://mcp.example.com/mcp`，例如 `claude mcp add --transport http alphabound https://mcp.example.com/mcp`。
- **没有入站鉴权时网关只允许 loopback**；绑定非 loopback 地址而未开 OAuth / `ALPHABOUND_MCP_REQUIRE_TOKEN=1` 会拒绝启动。
- 入站 token 只在网关校验，**不会转发**给 daemon（daemon 始终收到网关自己的 token）。
- 轮换 `ALPHABOUND_API_TOKEN` 或更改 `ALPHABOUND_MCP_PUBLIC_URL` 会让所有已授权客户端失效（要求重新授权）。

端点、安全模型与限制见仓库 [`tools/alphabound-mcp/README.md`](https://github.com/talkincode/alphabound/blob/main/tools/alphabound-mcp/README.md)。

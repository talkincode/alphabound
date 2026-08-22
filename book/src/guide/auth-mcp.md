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

```bash
cd tools/alphabound-mcp
npm install
export ALPHABOUND_API_BASE=http://127.0.0.1:18180
export ALPHABOUND_API_TOKEN=...   # 与 daemon 相同
npm start                         # stdio，给 IDE
# 或本机 HTTP 网关：
# ALPHABOUND_MCP_BIND=127.0.0.1 ALPHABOUND_MCP_PORT=8723 npm run http
```

工具列表见 [`tools/alphabound-mcp/README.md`](https://github.com/talkincode/alphabound/blob/main/tools/alphabound-mcp/README.md)。  
规划背景：[AGENT_ANALYTICS_MCP_PLAN.md](https://github.com/talkincode/alphabound/blob/main/docs/AGENT_ANALYTICS_MCP_PLAN.md)。

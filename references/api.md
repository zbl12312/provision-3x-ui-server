# 3X-UI API calls used by this skill

These shapes were checked against the supplied 3X-UI 3.x OpenAPI document. The
main script first tries a reported API token. If that token is absent or invalid,
it logs in, obtains a CSRF token, creates a dedicated API token, and uses Bearer
authentication for provisioning.

Use the panel base path returned by 3X-UI:

```text
BASE_URL/panel/api
```

Send every request with:
a
```text
Authorization: Bearer API_TOKEN
Content-Type: application/json
```

## Endpoints

- `GET /inbounds/list`: list ports, inbounds, and attached clients.
- `POST /inbounds/add`: create a complete inbound payload.
- `POST /clients/add`: create one global client and attach it to inbound IDs.
- `GET /clients/get/{email}`: read the generated UUID and attachment IDs.
- `GET /clients/links/{email}`: return canonical share URLs.

## VLESS TCP inbound

```json
{
  "enable": true,
  "remark": "VLESS-TCP-NAME",
  "listen": "",
  "port": 28443,
  "protocol": "vless",
  "expiryTime": 0,
  "total": 0,
  "trafficReset": "never",
  "subSortIndex": 1,
  "shareAddrStrategy": "listen",
  "shareAddr": "",
  "settings": {
    "clients": [],
    "decryption": "none",
    "encryption": "none"
  },
  "streamSettings": {
    "network": "tcp",
    "security": "none",
    "tcpSettings": {
      "acceptProxyProtocol": false,
      "header": {"type": "none"}
    }
  },
  "sniffing": {"enabled": false}
}
```

Attach a generated client:

```json
{
  "client": {
    "email": "UNIQUE_NAME",
    "totalGB": 0,
    "expiryTime": 0,
    "tgId": 0,
    "limitIp": 0,
    "enable": true,
    "comment": "",
    "reset": 0,
    "security": "auto",
    "flow": ""
  },
  "inboundIds": [2]
}
```

## SOCKS5-compatible mixed inbound

3X-UI exposes SOCKS5 through the Xray `mixed` protocol:

```json
{
  "enable": true,
  "remark": "SOCKS5-NAME",
  "listen": "",
  "port": 17171,
  "protocol": "mixed",
  "expiryTime": 0,
  "total": 0,
  "trafficReset": "never",
  "subSortIndex": 1,
  "shareAddrStrategy": "listen",
  "shareAddr": "",
  "settings": {
    "auth": "password",
    "accounts": [{"user": "USER", "pass": "PASSWORD"}],
    "udp": false,
    "ip": "127.0.0.1"
  },
  "streamSettings": null,
  "sniffing": {"enabled": false}
}
```

Treat `success: true` as resource creation only. Delivery is complete only after a real proxy request returns the server public IP.

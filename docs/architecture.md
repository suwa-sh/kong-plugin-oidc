# Kong OIDC Plugin - C4 Model Architecture

## 1. コンテキスト図 (Context Diagram)

システム全体の境界と外部アクターの関係を示す。Kong Gateway と OIDC Plugin をシステム境界とし、外部のユーザー、認証プロバイダ、上流サービス、セッションストアとの関係を表現する。

```mermaid
C4Context
    title Kong OIDC Plugin - System Context Diagram

    Person(user, "End User", "Browser-based user accessing protected resources")

    System_Boundary(kong_system, "Kong Gateway + OIDC Plugin") {
        System(kong, "Kong API Gateway", "API Gateway with OIDC authentication plugin (DBless mode, declarative config)")
    }

    System_Ext(keycloak, "Keycloak", "OpenID Connect Provider - issues tokens, manages user sessions")
    System_Ext(upstream, "Upstream Services", "Backend services receiving authenticated requests")
    System_Ext(redis, "Redis", "Session store for OIDC session data (optional, alternative to cookie)")

    Rel(user, kong, "HTTP requests", "HTTP/8000")
    Rel(kong, keycloak, "OIDC discovery, token exchange, introspection", "HTTP")
    Rel(kong, upstream, "Proxied requests with injected auth headers", "HTTP")
    Rel(kong, redis, "Session read/write", "TCP/6379")
    Rel(keycloak, user, "Authentication redirect, login page", "HTTP/302")
```

## 2. コンテナ図 (Container Diagram)

インフラストラクチャを構成するコンテナ間の通信とポート、プロトコルを示す。全コンテナは Podman Pod 内で動作し、Pod 内ネットワーク (localhost) で通信する。

```mermaid
C4Container
    title Kong OIDC Plugin - Container Diagram

    Person(user, "End User", "Browser")

    Container_Boundary(pod, "Podman Pod: kong-oidc") {
        Container(kong, "Kong Gateway", "OpenResty/Lua", "API Gateway in DBless mode. Runs OIDC plugin (priority 1000). Ports: 8000 (proxy), 8001 (admin/metrics)")
        Container(oidc_plugin, "OIDC Plugin", "Lua (kong-oidc)", "Custom plugin: Authorization Code flow, Bearer JWT verify, Token Introspection, Session management")
        Container(traefik, "Traefik", "Traefik v3", "Reverse proxy for Keycloak. Routes /realms/* requests. Port: 8888")
        Container(keycloak, "Keycloak", "Keycloak 24.0.5", "OIDC Provider in dev mode. Port: 8080")
        Container(mockserver, "MockServer", "MockServer 5.15.0", "HTTP mock backend for testing. Port: 1080")
    }

    System_Ext(redis, "Redis", "Session store (optional)")

    Rel(user, kong, "HTTP requests to protected resources", "HTTP/8000")
    Rel(user, keycloak, "Keycloak admin console", "HTTP/8080")
    Rel(kong, oidc_plugin, "Access phase hook", "Lua internal")
    Rel(oidc_plugin, traefik, "OIDC discovery, token exchange, JWKS fetch", "HTTP/8888")
    Rel(traefik, keycloak, "Proxy /realms/* to Keycloak", "HTTP/8080")
    Rel(kong, mockserver, "Proxy upstream requests", "HTTP/1080")
    Rel(oidc_plugin, redis, "Session read/write", "TCP/6379")
    Rel(oidc_plugin, user, "302 redirect to Keycloak login", "HTTP")
```

## 3. コンポーネント図 (Component Diagram)

OIDC Plugin の内部構造を示す。各 Lua モジュールの責務と、外部ライブラリとの依存関係を表現する。

```mermaid
C4Component
    title Kong OIDC Plugin - Component Diagram

    Container_Boundary(oidc, "OIDC Plugin (kong/plugins/oidc/)") {
        Component(handler, "OidcHandler", "handler.lua", "Access phase entry point (PRIORITY 1000). Orchestrates authentication: verify_bearer_jwt -> introspect -> make_oidc (Authorization Code flow). Configures openidc log level.")
        Component(utils, "Utils", "utils.lua", "Config assembly (get_options), header injection (injectUser, injectAccessToken, injectIDToken, injectHeaders), credential management (setCredentials), group injection (injectGroups)")
        Component(filter, "Filter", "filter.lua", "URI pattern matching (shouldProcessRequest). Checks request path against configured filter patterns to skip OIDC processing.")
        Component(schema, "Schema", "schema.lua", "Kong plugin schema definition. Defines all configuration fields: client credentials, discovery URL, session timeouts, header names, bearer JWT settings, etc.")
    }

    Container_Boundary(deps, "External Libraries") {
        Component(openidc, "lua-resty-openidc", "v1.8.0", "OIDC library: authenticate() for Authorization Code flow, bearer_jwt_verify() for JWT validation, introspect() for token introspection, get_discovery_doc() for OIDC discovery")
        Component(session, "lua-resty-session", "v4.0.5", "Session management: cookie-based or Redis-based storage, session encryption, timeout management")
        Component(jwt_validators, "resty.jwt-validators", "Lua library", "JWT claim validation: issuer, audience, expiry, not-before checks with configurable leeway")
    }

    Rel(handler, utils, "get_options(), setCredentials(), injectUser(), injectAccessToken(), injectIDToken(), injectHeaders(), injectGroups(), has_bearer_access_token()")
    Rel(handler, filter, "shouldProcessRequest()")
    Rel(handler, openidc, "authenticate(), bearer_jwt_verify(), introspect(), get_discovery_doc()")
    Rel(handler, jwt_validators, "set_system_leeway(), equals(), required(), is_not_expired(), opt_is_not_before()")
    Rel(openidc, session, "Session create/read/update via cookie or Redis storage")
```

## 4. シーケンス図 (Sequence Diagrams)

以下のシーケンス図では、`lua-resty-openidc` 内部の動作（セッション操作、ディスカバリ取得、リダイレクト生成、コード交換等）はライブラリ委譲された処理として記載している。プラグインコードが直接実装しているのは `resty.openidc.authenticate()` / `bearer_jwt_verify()` / `introspect()` / `get_discovery_doc()` の呼び出しまでである。

### 4a. 初回認証フロー (Authorization Code Flow)

ユーザーが初めてアクセスした場合の認証フロー。セッションが存在しないため、Keycloak にリダイレクトして認証後、コールバックでトークンを取得し、セッションを保存する。

```mermaid
sequenceDiagram
    participant Client as End User (Browser)
    participant Kong as Kong Gateway
    participant Handler as OidcHandler
    participant Filter as filter.lua
    participant Utils as utils.lua
    participant OpenIDC as lua-resty-openidc
    participant Session as lua-resty-session
    participant Redis as Redis / Cookie
    participant Keycloak as Keycloak (via Traefik)
    participant Upstream as Upstream Service

    Client->>Kong: GET /some/path
    Kong->>Handler: access(config)
    Handler->>Utils: get_options(config, ngx)
    Utils-->>Handler: oidcConfig

    Note over Handler: skip_already_auth_requests check (early return if credential already set)

    Handler->>Filter: shouldProcessRequest(oidcConfig)
    Filter-->>Handler: true

    Note over Handler: bearer_jwt_auth_enable=off, introspection_endpoint=nil -> skip to make_oidc
    Handler->>OpenIDC: authenticate(oidcConfig, uri, "auth", session_config)
    OpenIDC->>Session: open session
    Session->>Redis: read session data
    Redis-->>Session: session not found
    Session-->>OpenIDC: no valid session

    OpenIDC->>Keycloak: GET /.well-known/openid-configuration
    Keycloak-->>OpenIDC: discovery document
    OpenIDC-->>Client: 302 Redirect to Keycloak /auth (with state, nonce)

    Client->>Keycloak: GET /realms/master/protocol/openid-connect/auth
    Keycloak-->>Client: Login page
    Client->>Keycloak: POST credentials
    Keycloak-->>Client: 302 Redirect to callback URI (with code, state)

    Client->>Kong: GET /some/path/callback?code=xxx&state=yyy
    Kong->>Handler: access(config)
    Handler->>Utils: get_options(config, ngx)
    Handler->>Filter: shouldProcessRequest(oidcConfig)
    Filter-->>Handler: true
    Handler->>OpenIDC: authenticate(oidcConfig, uri, "auth", session_config)

    OpenIDC->>Keycloak: POST /token (exchange code for tokens)
    Keycloak-->>OpenIDC: access_token, id_token, refresh_token

    OpenIDC->>Session: save session (id_token, enc_id_token, access_token)
    Session->>Redis: write session data
    Redis-->>Session: OK
    OpenIDC-->>Handler: {user, id_token, access_token}

    Handler->>Utils: setCredentials(user/id_token)
    Handler->>Utils: injectGroups(user/id_token, groups_claim)
    Handler->>Utils: injectHeaders(header_names, header_claims, sources)
    Handler->>Utils: injectUser(user, "X-USERINFO")
    Handler->>Utils: injectAccessToken(access_token, "X-Access-Token")
    Handler->>Utils: injectIDToken(id_token, "X-ID-Token")

    Kong->>Upstream: Proxied request with auth headers
    Upstream-->>Kong: Response
    Kong-->>Client: Response (with Set-Cookie for session)
```

### 4b. 認証済みリクエストフロー (Authenticated Request with Valid Session)

既に認証済みのユーザーがセッション Cookie を持ってアクセスする場合のフロー。セッションが有効であれば、認証プロバイダへの通信なしにリクエストを処理する。

```mermaid
sequenceDiagram
    participant Client as End User (Browser)
    participant Kong as Kong Gateway
    participant Handler as OidcHandler
    participant Filter as filter.lua
    participant Utils as utils.lua
    participant OpenIDC as lua-resty-openidc
    participant Session as lua-resty-session
    participant Redis as Redis / Cookie
    participant Upstream as Upstream Service

    Client->>Kong: GET /some/path (with session cookie)
    Kong->>Handler: access(config)
    Handler->>Utils: get_options(config, ngx)
    Utils-->>Handler: oidcConfig

    Note over Handler: skip_already_auth_requests check (early return if credential already set)

    Handler->>Filter: shouldProcessRequest(oidcConfig)
    Filter-->>Handler: true

    Note over Handler: bearer_jwt_auth_enable=off, introspection_endpoint=nil -> skip to make_oidc
    Handler->>OpenIDC: authenticate(oidcConfig, uri, "auth", session_config)
    OpenIDC->>Session: open session (from cookie)
    Session->>Redis: read session data
    Redis-->>Session: session data (id_token, access_token)
    Session-->>OpenIDC: valid session

    Note over OpenIDC: Session valid (within idling/rolling/absolute timeouts)

    OpenIDC-->>Handler: {user, id_token, access_token}

    Handler->>Utils: setCredentials(user/id_token)
    Handler->>Utils: injectGroups(user/id_token, groups_claim)
    Handler->>Utils: injectHeaders(header_names, header_claims, sources)
    Handler->>Utils: injectUser(user, "X-USERINFO")
    Handler->>Utils: injectAccessToken(access_token, "X-Access-Token")
    Handler->>Utils: injectIDToken(id_token, "X-ID-Token")

    Kong->>Upstream: Proxied request with auth headers
    Upstream-->>Kong: Response
    Kong-->>Client: Response
```

### 4c. セッション期限切れフロー (Session Expired Flow)

セッションが期限切れまたは無効になった場合のフロー。再認証のために Keycloak にリダイレクトされる。

```mermaid
sequenceDiagram
    participant Client as End User (Browser)
    participant Kong as Kong Gateway
    participant Handler as OidcHandler
    participant Filter as filter.lua
    participant Utils as utils.lua
    participant OpenIDC as lua-resty-openidc
    participant Session as lua-resty-session
    participant Redis as Redis / Cookie
    participant Keycloak as Keycloak (via Traefik)

    Client->>Kong: GET /some/path (with expired session cookie)
    Kong->>Handler: access(config)
    Handler->>Utils: get_options(config, ngx)
    Utils-->>Handler: oidcConfig

    Note over Handler: skip_already_auth_requests check (early return if credential already set)

    Handler->>Filter: shouldProcessRequest(oidcConfig)
    Filter-->>Handler: true

    Note over Handler: bearer_jwt_auth_enable=off, introspection_endpoint=nil -> skip to make_oidc
    Handler->>OpenIDC: authenticate(oidcConfig, uri, "auth", session_config)
    OpenIDC->>Session: open session (from cookie)
    Session->>Redis: read session data
    Redis-->>Session: session data found

    Note over Session: Session expired (idling_timeout, rolling_timeout, or absolute_timeout exceeded)

    Session-->>OpenIDC: session expired / invalid
    OpenIDC->>Session: destroy expired session
    Session->>Redis: delete session data
    Redis-->>Session: OK

    OpenIDC-->>Client: 302 Redirect to Keycloak /auth (with new state, nonce)

    Note over Client,Keycloak: Re-authentication flow begins (same as initial authentication)

    Client->>Keycloak: GET /realms/master/protocol/openid-connect/auth
    Keycloak-->>Client: Login page (or SSO if Keycloak session still valid)
```

### 4d. Bearer JWT 認証フロー

`bearer_jwt_auth_enable` が有効な場合、Authorization ヘッダーの Bearer トークンを JWKS で検証する。セッション不要で、Keycloak へのリダイレクトは発生しない。

```mermaid
sequenceDiagram
    participant Client as API Client
    participant Kong as Kong Gateway
    participant Handler as OidcHandler
    participant Utils as utils.lua
    participant OpenIDC as lua-resty-openidc
    participant Keycloak as Keycloak (via Traefik)
    participant Upstream as Upstream Service

    Client->>Kong: GET /api/resource (Authorization: Bearer <JWT>)
    Kong->>Handler: access(config)
    Handler->>Utils: get_options(config, ngx)

    Note over Handler: bearer_jwt_auth_enable=on, bearer token detected

    Handler->>OpenIDC: get_discovery_doc(opts)
    OpenIDC->>Keycloak: GET /.well-known/openid-configuration (cached)
    Keycloak-->>OpenIDC: discovery document
    Handler->>OpenIDC: bearer_jwt_verify(opts, claim_spec)
    OpenIDC->>Keycloak: GET /certs (JWKS, cached)
    Keycloak-->>OpenIDC: JSON Web Key Set
    OpenIDC-->>Handler: verified JWT claims

    Handler->>Utils: setCredentials(claims)
    Handler->>Utils: injectGroups(claims, groups_claim)
    Handler->>Utils: injectHeaders(header_names, header_claims, sources)
    Handler->>Utils: injectUser(claims, "X-USERINFO")

    Kong->>Upstream: Proxied request with auth headers
    Upstream-->>Kong: Response
    Kong-->>Client: Response

    Note over Handler: JWT verification failure -> return nil, fall through to introspect/make_oidc
```

### 4e. エラーフロー

認証失敗時のレスポンス分岐を示す。

```mermaid
sequenceDiagram
    participant Client
    participant Kong as Kong Gateway
    participant Handler as OidcHandler

    Note over Handler: bearer_only="yes" + introspection error
    Handler-->>Client: 401 Unauthorized (WWW-Authenticate: Bearer realm="kong", error="...")

    Note over Handler: validate_scope="yes" + scope mismatch
    Handler-->>Client: 403 Forbidden

    Note over Handler: authenticate() error = "unauthorized request"
    Handler-->>Client: 401 Unauthorized

    Note over Handler: authenticate() other error + recovery_page_path set
    Handler-->>Client: 302 Redirect to recovery_page_path

    Note over Handler: authenticate() other error + no recovery page
    Handler-->>Client: 500 Internal Server Error
```

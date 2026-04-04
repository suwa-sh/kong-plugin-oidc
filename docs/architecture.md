# Kong OIDC Plugin - Architecture

## 1. コンテキスト図 (Context Diagram)

システム全体の境界と外部アクターの関係を示す。Kong Gateway + OIDC Plugin をシステム境界とし、外部のユーザー、認証プロバイダ、上流サービス、セッションストアとの通信フローを表現する。

```mermaid
graph TB
    User["End User (Browser)"]
    Kong["Kong Gateway + OIDC Plugin"]
    Keycloak["Keycloak (OIDC Provider)"]
    Upstream["Upstream Services"]
    Redis["Redis (Session Store, optional)"]

    User -- "HTTP :8000" --> Kong
    Kong -- "OIDC / Token" --> Keycloak
    Kong -- "Proxy" --> Upstream
    Kong -. "Session R/W" .-> Redis
    Keycloak -- "302 Redirect" --> User
```

## 2. コンテナ図 (Container Diagram)

Podman Pod 内のコンテナ配置とルーティングを示す。Kong はリクエストを受け付け、認証時は Traefik 経由で Keycloak と通信し、認証後は MockServer（バックエンド）へプロキシする。

```mermaid
graph LR
    User["End User"]

    subgraph Pod["Docker Pod"]
        Kong["Kong (:8000 / :8001)"]
        Traefik["Traefik (:8888)"]
        Keycloak["Keycloak (:8080)"]
        MockServer["MockServer (:1080)"]
        Redis["Redis (:6379)"]
    end

    User -- ":8000" --> Kong
    Kong -- ":1080" --> MockServer
    Kong -- ":8888" --> Traefik
    Traefik -- ":8080" --> Keycloak
    Kong -- "Session R/W" --> Redis
```

### 2.1. コンテナ間シーケンス図

コンテナ図の構成要素を participant として、主要な認証フローをまとめて示す。

```mermaid
sequenceDiagram
    participant User as End User
    participant Kong as Kong
    participant Traefik as Traefik
    participant Keycloak as Keycloak
    participant Redis as Redis
    participant Mock as MockServer

    Note over User,Mock: 初回認証フロー (Authorization Code Flow)

    User->>Kong: GET /some/path
    Kong->>Redis: セッション読み取り
    Redis-->>Kong: セッションなし
    Kong->>Traefik: OIDC ディスカバリ取得
    Traefik->>Keycloak: GET /.well-known/openid-configuration
    Keycloak-->>Traefik: ディスカバリドキュメント
    Traefik-->>Kong: ディスカバリドキュメント
    Kong-->>User: 302 Redirect to Keycloak
    User->>Keycloak: ログインページ表示・認証
    Keycloak-->>User: 302 Redirect to callback (code, state)
    User->>Kong: GET /callback?code=xxx&state=yyy
    Kong->>Traefik: POST /token (code exchange)
    Traefik->>Keycloak: POST /token
    Keycloak-->>Traefik: access_token, id_token
    Traefik-->>Kong: access_token, id_token
    Kong->>Redis: セッション保存
    Redis-->>Kong: OK
    Kong->>Mock: プロキシ (認証ヘッダー付き)
    Mock-->>Kong: レスポンス
    Kong-->>User: レスポンス (Set-Cookie)

    Note over User,Mock: 認証済みリクエスト (セッション有効)

    User->>Kong: GET /some/path (session cookie)
    Kong->>Redis: セッション読み取り
    Redis-->>Kong: セッションデータ (有効)
    Kong->>Mock: プロキシ (認証ヘッダー付き)
    Mock-->>Kong: レスポンス
    Kong-->>User: レスポンス

    Note over User,Mock: セッション期限切れ

    User->>Kong: GET /some/path (expired cookie)
    Kong->>Redis: セッション読み取り
    Redis-->>Kong: セッション期限切れ
    Kong->>Redis: セッション削除
    Kong-->>User: 302 Redirect to Keycloak
    User->>Keycloak: 再認証 (SSO or ログイン)

    Note over User,Mock: Bearer JWT 認証 (API アクセス)

    User->>Kong: GET /api (Authorization: Bearer JWT)
    Kong->>Traefik: JWKS 取得 (cached)
    Traefik->>Keycloak: GET /certs
    Keycloak-->>Traefik: JWKS
    Traefik-->>Kong: JWKS
    Kong->>Kong: JWT 署名・クレーム検証
    Kong->>Mock: プロキシ (認証ヘッダー付き)
    Mock-->>Kong: レスポンス
    Kong-->>User: レスポンス
```

## 3. コンポーネント図 (Component Diagram)

OIDC Plugin を構成する Lua モジュールと外部ライブラリの依存関係を示す。handler.lua がエントリポイントとなり、認証処理を統括する。

```mermaid
graph TB
    subgraph Plugin["OIDC Plugin"]
        handler["handler.lua (entry point)"]
        utils["utils.lua"]
        filter["filter.lua"]
        schema["schema.lua"]
    end

    subgraph Libs["External Libraries"]
        openidc["lua-resty-openidc"]
        session["lua-resty-session"]
        jwt["resty.jwt-validators"]
    end

    handler -- "get_options, injectHeaders,\nsetCredentials" --> utils
    handler -- "shouldProcessRequest" --> filter
    handler -- "authenticate, bearer_jwt_verify,\nintrospect" --> openidc
    handler -- "set_system_leeway,\nequals, is_not_expired" --> jwt
    openidc -- "Session管理" --> session
    schema -. "config定義" .-> handler
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

## 5. データモデル (Data Model)

### 5.1. 概念データモデル

プラグイン内で扱う主要なデータ概念とその関係を示す。

```mermaid
graph TB
    Config["Plugin Config"]
    OidcConfig["oidcConfig"]
    SessionConfig["session_config"]
    Session["Session"]
    AuthResponse["Auth Response"]
    Credential["Kong Credential"]
    Headers["Upstream Headers"]

    Config -- "get_options()で変換" --> OidcConfig
    OidcConfig -- "session_opts抽出" --> SessionConfig
    SessionConfig -- "セッション管理" --> Session
    OidcConfig -- "認証処理" --> AuthResponse
    AuthResponse -- "setCredentials()" --> Credential
    AuthResponse -- "inject*()" --> Headers
```

| 要素 | 説明 |
|------|------|
| Plugin Config | Kong の宣言的設定（`kong.yml`）または Admin API から渡されるプラグイン設定。`schema.lua` で定義 |
| oidcConfig | `utils.get_options()` で Plugin Config から変換された実行時設定。文字列の `"yes"/"no"` を boolean に変換し、フィルタパターンをパース済み |
| session_config | `make_oidc()` で oidcConfig から抽出されたセッション設定。Cookie 名、暗号化シークレット、タイムアウト、Redis 接続情報を含む |
| Session | `lua-resty-session` が管理するセッションデータ。Cookie または Redis に暗号化して保存。`session_contents` で保存対象を制御（id_token, enc_id_token, access_token） |
| Auth Response | `lua-resty-openidc` の認証結果。認証方式により構造が異なる（Authorization Code: user + id_token + access_token、Bearer JWT / Introspection: トークンクレーム直接） |
| Kong Credential | `setCredentials()` で設定される Kong 認証情報。`sub` → `id`、`preferred_username` → `username` にマッピングし、`kong.client.authenticate()` に渡す |
| Upstream Headers | バックエンドに注入される認証ヘッダー。`X-USERINFO`（Base64）、`X-Access-Token`、`X-ID-Token`（Base64）、および `header_names`/`header_claims` で定義されたカスタムヘッダー |

### 5.2. 論理データモデル

各データ概念の主要な属性をクラス図で示す。

```mermaid
classDiagram
    class PluginConfig {
        client_id: string
        client_secret: string
        discovery: string
        redirect_uri: string
        unauth_action: string
        bearer_jwt_auth_enable: string
        session_storage: string
        session_redis_host: string
        encryption_secret: string
    }

    class oidcConfig {
        client_id: string
        client_secret: string
        discovery: string
        bearer_jwt_auth_enable: boolean
        introspection_endpoint: string
        filters: table
        session_contents: table
        session_opts: table
    }

    class session_config {
        cookie_name: string
        secret: string
        idling_timeout: number
        rolling_timeout: number
        absolute_timeout: number
        storage: string
        redis: table
    }

    class Session {
        id_token: table
        enc_id_token: string
        access_token: string
        user: table
    }

    class AuthResponse {
        user: table
        id_token: table
        access_token: string
    }

    class Credential {
        id: string
        username: string
        sub: string
        preferred_username: string
    }

    class UpstreamHeaders {
        X_USERINFO: base64
        X_Access_Token: string
        X_ID_Token: base64
        X_Credential_Identifier: string
    }

    PluginConfig --> oidcConfig : get_options()
    oidcConfig --> session_config : make_oidc()
    session_config --> Session : lua-resty-session
    oidcConfig --> AuthResponse : authenticate / verify
    AuthResponse --> Credential : setCredentials()
    AuthResponse --> UpstreamHeaders : inject*()
```

### 5.3. データフロー

概念データモデル上でのデータの流れを、認証フェーズごとに示す。

```mermaid
graph LR
    subgraph Input["入力"]
        Req["HTTP Request"]
        Cookie["Session Cookie"]
        Bearer["Bearer Token"]
    end

    subgraph Transform["変換 (OIDC Plugin)"]
        Config["Plugin Config"]
        OidcConf["oidcConfig"]
        SessConf["session_config"]
    end

    subgraph Auth["認証"]
        MakeOIDC["Authorization Code"]
        Introspect["Introspection"]
        JWT["Bearer JWT Verify"]
    end

    subgraph Store["ストレージ"]
        RedisSess["Redis / Cookie"]
    end

    subgraph Output["出力"]
        Cred["Kong Credential"]
        Hdrs["Upstream Headers"]
    end

    Req --> Config
    Config -- "get_options()" --> OidcConf
    OidcConf -- "session_opts" --> SessConf
    SessConf --> RedisSess

    Cookie --> RedisSess
    RedisSess -- "session data" --> MakeOIDC

    Bearer --> JWT
    OidcConf --> MakeOIDC
    OidcConf --> Introspect
    OidcConf --> JWT

    MakeOIDC --> Cred
    MakeOIDC --> Hdrs
    Introspect --> Cred
    Introspect --> Hdrs
    JWT --> Cred
    JWT --> Hdrs

    MakeOIDC -- "セッション保存" --> RedisSess
```

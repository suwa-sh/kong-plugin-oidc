-- spec/unit/helpers/mocks.lua
-- 共有モック: ngx, kong, cjson, kong.constants, resty.openidc, resty.jwt-validators
local M = {}

-- plugin モジュールのキー一覧（require キャッシュクリア用）
local plugin_modules = {
  "kong.plugins.oidc.filter",
  "kong.plugins.oidc.utils",
  "kong.plugins.oidc.handler",
}

-- mock モジュールのキー一覧
local mock_modules = {
  "cjson",
  "kong.constants",
  "resty.openidc",
  "resty.jwt-validators",
}

---------------------------------------------------------------------------
-- ngx mock
---------------------------------------------------------------------------
local function create_ngx()
  return {
    DEBUG = 8,
    INFO  = 7,
    NOTICE = 6,
    WARN  = 5,
    ERR   = 4,
    CRIT  = 3,
    HTTP_UNAUTHORIZED          = 401,
    HTTP_FORBIDDEN             = 403,
    HTTP_INTERNAL_SERVER_ERROR = 500,

    var = {
      uri = "/",
      request_uri = "/",
    },
    req = {
      get_uri_args = function() return {} end,
      get_headers  = function() return {} end,
    },
    log          = function() end,
    encode_base64 = function(s) return "b64:" .. s end,
    redirect     = function() end,
    header       = {},
  }
end

---------------------------------------------------------------------------
-- kong mock
---------------------------------------------------------------------------
local function create_kong()
  return {
    service = {
      request = {
        set_header   = function() end,
        clear_header = function() end,
      },
    },
    client = {
      authenticate   = function() end,
      get_credential = function() return nil end,
    },
    ctx = {
      shared = {},
    },
    response = {
      error = function() end,
    },
    log = {
      err = function() end,
    },
  }
end

---------------------------------------------------------------------------
-- package.loaded mocks
---------------------------------------------------------------------------
local function create_cjson_mock()
  return {
    encode = function(t) return "json:" .. tostring(t) end,
    decode = function(s) return s end,
  }
end

local function create_constants_mock()
  return {
    HEADERS = {
      CONSUMER_ID        = "X-Consumer-ID",
      CONSUMER_CUSTOM_ID = "X-Consumer-Custom-ID",
      CONSUMER_USERNAME  = "X-Consumer-Username",
      CREDENTIAL_IDENTIFIER = "X-Credential-Identifier",
      ANONYMOUS          = "X-Anonymous-Consumer",
    },
  }
end

local function create_openidc_mock()
  return {
    authenticate      = function() return {}, nil end,
    introspect        = function() return {}, nil end,
    bearer_jwt_verify = function() return {}, nil end,
    get_discovery_doc = function() return { issuer = "https://example.com" }, nil end,
    set_logging       = function() end,
  }
end

local function create_jwt_validators_mock()
  return {
    set_system_leeway  = function() end,
    equals             = function(val) return function() return val end end,
    required           = function() return function() return true end end,
    is_not_expired     = function() return function() return true end end,
    opt_is_not_before  = function() return function() return true end end,
  }
end

---------------------------------------------------------------------------
-- Kong DB schema mock (handler.lua requires utils → utils requires cjson/constants,
-- handler requires filter; schema.lua requires kong.db.schema.typedefs)
-- We also need to mock kong.db.schema.typedefs for schema.lua if ever loaded.
---------------------------------------------------------------------------
local function create_typedefs_mock()
  return {
    no_consumer    = { type = "record" },
    protocols_http = { type = "set" },
  }
end

---------------------------------------------------------------------------
-- Config factory
---------------------------------------------------------------------------
function M.make_config(overrides)
  local config = {
    client_id                              = "test-client",
    client_secret                          = "test-secret",
    discovery                              = "https://example.com/.well-known/openid-configuration",
    introspection_cache_ignore             = "no",
    bearer_only                            = "no",
    realm                                  = "kong",
    scope                                  = "openid",
    validate_scope                         = "no",
    response_type                          = "code",
    ssl_verify                             = "no",
    use_jwks                               = "no",
    token_endpoint_auth_method             = "client_secret_post",
    encryption_secret                      = "test-encryption-secret",
    session_idling_timeout                 = 0,
    session_rolling_timeout                = 0,
    session_absolute_timeout               = 0,
    session_remember_rolling_timeout       = 0,
    session_remember_absolute_timeout      = 0,
    session_storage                        = "cookie",
    session_redis_host                     = "127.0.0.1",
    session_redis_port                     = 6379,
    session_redis_database                 = 0,
    session_redis_ssl                      = "no",
    logout_path                            = "/logout",
    redirect_after_logout_uri              = "/",
    redirect_after_logout_with_id_token_hint = "no",
    unauth_action                          = "auth",
    userinfo_header_name                   = "X-USERINFO",
    id_token_header_name                   = "X-ID-Token",
    access_token_header_name               = "X-Access-Token",
    access_token_as_bearer                 = "no",
    disable_userinfo_header                = "no",
    disable_id_token_header                = "no",
    disable_access_token_header            = "no",
    revoke_tokens_on_logout                = "no",
    groups_claim                           = "groups",
    skip_already_auth_requests             = "no",
    bearer_jwt_auth_enable                 = "no",
    bearer_jwt_auth_signing_algs           = { "RS256" },
    header_names                           = {},
    header_claims                          = {},
    openidc_debug_log_level                = "ngx.DEBUG",
  }
  if overrides then
    for k, v in pairs(overrides) do
      config[k] = v
    end
  end
  return config
end

---------------------------------------------------------------------------
-- setup / reset / teardown
---------------------------------------------------------------------------
function M.setup()
  -- グローバル設置
  _G.ngx  = create_ngx()
  _G.kong = create_kong()

  -- package.loaded にモック登録
  package.loaded["cjson"]                = create_cjson_mock()
  package.loaded["kong.constants"]       = create_constants_mock()
  package.loaded["kong.db.schema.typedefs"] = create_typedefs_mock()
  package.loaded["resty.openidc"]        = create_openidc_mock()
  package.loaded["resty.jwt-validators"] = create_jwt_validators_mock()

  -- プラグインモジュールのキャッシュをクリア（setup 時に新鮮な状態で require させる）
  for _, mod in ipairs(plugin_modules) do
    package.loaded[mod] = nil
  end
end

function M.reset()
  -- ngx 状態リセット（全フィールドを初期値に戻す）
  _G.ngx.var = { uri = "/", request_uri = "/" }
  _G.ngx.header = {}
  _G.ngx.req.get_uri_args = function() return {} end
  _G.ngx.req.get_headers  = function() return {} end
  _G.ngx.log          = function() end
  _G.ngx.redirect     = function() end
  _G.ngx.encode_base64 = function(s) return "b64:" .. s end

  -- kong 状態リセット（全関数を初期値に戻す）
  _G.kong.ctx.shared = {}
  _G.kong.client.get_credential = function() return nil end
  _G.kong.client.authenticate   = function() end
  _G.kong.service.request.set_header   = function() end
  _G.kong.service.request.clear_header = function() end
  _G.kong.response.error = function() end
  _G.kong.log.err        = function() end

  -- openidc mock リセット（デフォルト戻り値に戻す）
  local openidc = package.loaded["resty.openidc"]
  openidc.authenticate      = function() return {}, nil end
  openidc.introspect        = function() return {}, nil end
  openidc.bearer_jwt_verify = function() return {}, nil end
  openidc.get_discovery_doc = function() return { issuer = "https://example.com" }, nil end
  openidc.set_logging       = function() end
end

function M.teardown()
  -- プラグインモジュールのキャッシュクリア
  for _, mod in ipairs(plugin_modules) do
    package.loaded[mod] = nil
  end
  -- mock モジュールのキャッシュクリア
  for _, mod in ipairs(mock_modules) do
    package.loaded[mod] = nil
  end
  package.loaded["kong.db.schema.typedefs"] = nil

  -- グローバル除去
  _G.ngx  = nil
  _G.kong = nil
end

return M

local OidcHandler = {
    VERSION = "1.7.0",
    PRIORITY = 1000,
}
-- luacheck: ignore 212/self
local utils = require("kong.plugins.oidc.utils")
local filter = require("kong.plugins.oidc.filter")
local handle, make_oidc, introspect, verify_bearer_jwt

-- Build a sources table that excludes nil values.
-- Lua の { nil, x } のようなテーブルリテラルは nil ホールを生成し
-- `#t` の結果が未定義になるため、nil を除外したテーブルを明示的に構築する。
local function non_nil_sources(...)
  local sources = {}
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if v then
      sources[#sources + 1] = v
    end
  end
  return sources
end

-- OAuth/OIDC のスコープはスペース区切りリストとして扱う。
-- 必須スコープ（required_scope）に含まれるすべてのスコープが
-- トークン側スコープ（token_scope）に含まれているかを検証する。
local function token_contains_required_scopes(token_scope, required_scope)
  if type(token_scope) ~= "string" or type(required_scope) ~= "string" then
    return false
  end
  local token_scopes = {}
  for scope in token_scope:gmatch("%S+") do
    token_scopes[scope] = true
  end
  local has_required = false
  for required in required_scope:gmatch("%S+") do
    has_required = true
    if not token_scopes[required] then
      return false
    end
  end
  return has_required
end

function OidcHandler:configure(configs)
  -- Map openidc debug log level to configured Nginx log level
  -- Iterate through all configs and take the highest priority (least verbose) level
  if configs and #configs > 0 then
    local level_mapping = {
      ["ngx.DEBUG"] = ngx.DEBUG,
      ["ngx.INFO"] = ngx.INFO,
      ["ngx.WARN"] = ngx.WARN,
      ["ngx.ERR"] = ngx.ERR
    }

    local level_priority = {
      [ngx.DEBUG] = 1,
      [ngx.INFO] = 2,
      [ngx.WARN] = 3,
      [ngx.ERR] = 4
    }

    local highest_level = ngx.DEBUG
    local highest_priority = 1
    local selected_level_name = "ngx.DEBUG"

    for _, config in ipairs(configs) do
      if config and config.openidc_debug_log_level then
        local mapped_level = level_mapping[config.openidc_debug_log_level]
        if mapped_level and level_priority[mapped_level] > highest_priority then
          highest_level = mapped_level
          highest_priority = level_priority[mapped_level]
          selected_level_name = config.openidc_debug_log_level
        end
      end
    end

    -- Configure openidc library to use the mapped log level
    local openidc = require("resty.openidc")
    openidc.set_logging(nil, {
      DEBUG = highest_level,
      ERROR = ngx.ERR,
      WARN = ngx.WARN
    })

    ngx.log(ngx.INFO, "OIDC plugin configured openidc debug log level to: " .. selected_level_name)
  end
end

function OidcHandler:access(config)
  local oidcConfig = utils.get_options(config, ngx)

  -- partial support for plugin chaining: allow skipping requests, where higher priority
  -- plugin has already set the credentials. The 'config.anomyous' approach to define
  -- "and/or" relationship between auth plugins is not utilized
  if oidcConfig.skip_already_auth_requests and kong.client.get_credential() then
    ngx.log(ngx.DEBUG, "OidcHandler ignoring already auth request: " .. ngx.var.request_uri)
    return
  end

  if filter.shouldProcessRequest(oidcConfig) then
    handle(oidcConfig)
  else
    ngx.log(ngx.DEBUG, "OidcHandler ignoring request, path: " .. ngx.var.request_uri)
  end

  ngx.log(ngx.DEBUG, "OidcHandler done")
end

handle = function(oidcConfig)
  local response

  if oidcConfig.bearer_jwt_auth_enable then
    response = verify_bearer_jwt(oidcConfig)
    if response then
      utils.setCredentials(response)
      utils.injectGroups(response, oidcConfig.groups_claim)
      utils.injectHeaders(oidcConfig.header_names, oidcConfig.header_claims, { response })
      if not oidcConfig.disable_userinfo_header then
        utils.injectUser(response, oidcConfig.userinfo_header_name)
      end
      return
    end
  end

  if oidcConfig.introspection_endpoint then
    response = introspect(oidcConfig)
    if response then
      utils.setCredentials(response)
      utils.injectGroups(response, oidcConfig.groups_claim)
      utils.injectHeaders(oidcConfig.header_names, oidcConfig.header_claims, { response })
      if not oidcConfig.disable_userinfo_header then
        utils.injectUser(response, oidcConfig.userinfo_header_name)
      end
    end
  end

  if response == nil then
    response = make_oidc(oidcConfig)
    if response then
      if response.user or response.id_token then
        -- is there any scenario where lua-resty-openidc would not provide id_token?
        utils.setCredentials(response.user or response.id_token)
      end
      if response.user and response.user[oidcConfig.groups_claim]  ~= nil then
        utils.injectGroups(response.user, oidcConfig.groups_claim)
      elseif response.id_token then
        utils.injectGroups(response.id_token, oidcConfig.groups_claim)
      end
      utils.injectHeaders(oidcConfig.header_names, oidcConfig.header_claims, non_nil_sources(response.user, response.id_token))
      if (not oidcConfig.disable_userinfo_header
          and response.user) then
        utils.injectUser(response.user, oidcConfig.userinfo_header_name)
      end
      if (not oidcConfig.disable_access_token_header
          and response.access_token) then
        utils.injectAccessToken(response.access_token, oidcConfig.access_token_header_name, oidcConfig.access_token_as_bearer)
      end
      if (not oidcConfig.disable_id_token_header
          and response.id_token) then
        utils.injectIDToken(response.id_token, oidcConfig.id_token_header_name)
      end
    end
  end
end

make_oidc = function(oidcConfig)
  ngx.log(ngx.DEBUG, "OidcHandler calling authenticate, requested path: " .. ngx.var.request_uri)
  local unauth_action = oidcConfig.unauth_action
  if unauth_action ~= "auth" then
    -- constant for resty.oidc library
    unauth_action = "deny"
  end
  local session_config = {
    cookie_name = oidcConfig.cookie_name,
    secret = oidcConfig.encryption_secret,
    idling_timeout = oidcConfig.session_opts.idling_timeout,
    rolling_timeout = oidcConfig.session_opts.rolling_timeout,
    absolute_timeout = oidcConfig.session_opts.absolute_timeout,
    remember_rolling_timeout = oidcConfig.session_opts.remember_rolling_timeout,
    remember_absolute_timeout = oidcConfig.session_opts.remember_absolute_timeout,
  }

  if oidcConfig.session_opts.storage == "redis" then
    session_config.storage = "redis"
    session_config.redis = {
      host = oidcConfig.session_opts.redis_host,
      port = oidcConfig.session_opts.redis_port,
      password = oidcConfig.session_opts.redis_password,
      database = oidcConfig.session_opts.redis_database,
      ssl = oidcConfig.session_opts.redis_ssl,
    }
  end

  local res, err = require("resty.openidc").authenticate(oidcConfig, ngx.var.request_uri, unauth_action, session_config)

  if err then
    if err == 'unauthorized request' then
      return kong.response.error(ngx.HTTP_UNAUTHORIZED)
    else
      if oidcConfig.recovery_page_path then
        ngx.log(ngx.DEBUG, "Redirecting to recovery page: " .. oidcConfig.recovery_page_path)
        ngx.redirect(oidcConfig.recovery_page_path)
      end
      return kong.response.error(ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
  end
  return res
end

introspect = function(oidcConfig)
  if utils.has_bearer_access_token() or oidcConfig.bearer_only == "yes" then
    local res, err
    if oidcConfig.use_jwks == "yes" then
      res, err = require("resty.openidc").bearer_jwt_verify(oidcConfig)
    else
      res, err = require("resty.openidc").introspect(oidcConfig)
    end
    if err then
      if oidcConfig.bearer_only == "yes" then
        local realm = utils.sanitize_header_value(oidcConfig.realm)
        local error_value = utils.sanitize_header_value(err)
        ngx.header["WWW-Authenticate"] = 'Bearer realm="' .. realm .. '",error="' .. error_value .. '"' -- luacheck: ignore 122
        return kong.response.error(ngx.HTTP_UNAUTHORIZED)
      end
      return nil
    end
    if oidcConfig.validate_scope == "yes" then
      if not token_contains_required_scopes(res.scope, oidcConfig.scope) then
        kong.log.err("Scope validation failed")
        return kong.response.error(ngx.HTTP_FORBIDDEN)
      end
    end
    ngx.log(ngx.DEBUG, "OidcHandler introspect succeeded, requested path: " .. ngx.var.request_uri)
    return res
  end
  return nil
end

verify_bearer_jwt = function(oidcConfig)
  if not utils.has_bearer_access_token() then
    return nil
  end
  -- setup controlled configuration for bearer_jwt_verify
  local opts = {
    accept_none_alg = false,
    accept_unsupported_alg = false,
    token_signing_alg_values_expected = oidcConfig.bearer_jwt_auth_signing_algs,
    discovery = oidcConfig.discovery,
    timeout = oidcConfig.timeout,
    ssl_verify = oidcConfig.ssl_verify
  }

  local discovery_doc, err = require("resty.openidc").get_discovery_doc(opts)
  if err then
    kong.log.err('Discovery document retrieval for Bearer JWT verify failed')
    return nil
  end

  local allowed_auds = oidcConfig.bearer_jwt_auth_allowed_auds or oidcConfig.client_id

  local jwt_validators = require "resty.jwt-validators"
  jwt_validators.set_system_leeway(120)
  local claim_spec = {
    -- mandatory for id token: iss, sub, aud, exp, iat
    iss = jwt_validators.equals(discovery_doc.issuer),
    sub = jwt_validators.required(),
    aud = function(val) return utils.has_common_item(val, allowed_auds) end,
    exp = jwt_validators.is_not_expired(),
    iat = jwt_validators.required(),
    -- optional validations
    nbf = jwt_validators.opt_is_not_before(),
  }

  local json
  json, err = require("resty.openidc").bearer_jwt_verify(opts, claim_spec)
  if err then
    kong.log.err('Bearer JWT verify failed: ' .. err)
    return nil
  end

  return json
end

return OidcHandler

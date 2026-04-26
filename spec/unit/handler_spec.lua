local mocks = require("spec.unit.helpers.mocks")

describe("handler", function()
  local handler

  setup(function()
    mocks.setup()
    handler = require("kong.plugins.oidc.handler")
  end)

  before_each(function()
    mocks.reset()
  end)

  teardown(function()
    mocks.teardown()
  end)

  ---------------------------------------------------------------------------
  -- configure (H-01 〜 H-02)
  ---------------------------------------------------------------------------
  describe("configure", function()
    -- H-01
    it("複数設定の場合_最も抑制的なログレベルが選択されること", function()
      local set_logging_args
      package.loaded["resty.openidc"].set_logging = function(_, levels)
        set_logging_args = levels
      end

      handler:configure({
        { openidc_debug_log_level = "ngx.DEBUG" },
        { openidc_debug_log_level = "ngx.ERR" },
        { openidc_debug_log_level = "ngx.INFO" },
      })

      assert.is_not_nil(set_logging_args)
      assert.are.equal(ngx.ERR, set_logging_args.DEBUG)
    end)

    -- H-02
    it("configs空の場合_エラーにならないこと", function()
      assert.has_no.errors(function()
        handler:configure({})
      end)
    end)
  end)

  ---------------------------------------------------------------------------
  -- access (H-03 〜 H-05)
  ---------------------------------------------------------------------------
  describe("access", function()
    describe("access", function()
      -- H-03
      it("skip_already_auth有効で認証済みの場合_処理をスキップすること", function()
        local authenticate_called = false
        package.loaded["resty.openidc"].authenticate = function()
          authenticate_called = true
          return {}, nil
        end
        kong.client.get_credential = function() return { id = "existing" } end
        local config = mocks.make_config({ skip_already_auth_requests = "yes" })

        handler:access(config)

        assert.is_false(authenticate_called)
      end)

      -- H-04
      it("フィルタに一致する場合_処理をスキップすること", function()
        local authenticate_called = false
        package.loaded["resty.openidc"].authenticate = function()
          authenticate_called = true
          return {}, nil
        end
        ngx.var.uri = "/health"
        ngx.var.request_uri = "/health"
        local config = mocks.make_config({ filters = "/health" })

        handler:access(config)

        assert.is_false(authenticate_called)
      end)

      -- H-05
      it("通常リクエストの場合_handleが呼ばれること", function()
        local authenticate_called = false
        package.loaded["resty.openidc"].authenticate = function()
          authenticate_called = true
          return { user = { sub = "u1" }, id_token = { sub = "u1" }, access_token = "tok" }, nil
        end
        ngx.var.uri = "/api/data"
        ngx.var.request_uri = "/api/data"
        local config = mocks.make_config()

        handler:access(config)

        assert.is_true(authenticate_called)
      end)
    end)

    ---------------------------------------------------------------------------
    -- handle - auth method dispatch (H-06 〜 H-08b)
    ---------------------------------------------------------------------------
    describe("handle", function()
      -- H-06
      it("bearer_jwt有効の場合_verify_bearer_jwtが最初に呼ばれること", function()
        ngx.req.get_headers = function()
          return { Authorization = "Bearer jwt-token" }
        end
        local jwt_verify_called = false
        package.loaded["resty.openidc"].bearer_jwt_verify = function()
          jwt_verify_called = true
          return { sub = "u1", preferred_username = "user1" }, nil
        end
        package.loaded["resty.openidc"].get_discovery_doc = function()
          return { issuer = "https://example.com" }, nil
        end
        local authenticate_called = false
        package.loaded["resty.openidc"].authenticate = function()
          authenticate_called = true
          return {}, nil
        end
        ngx.var.uri = "/api"
        ngx.var.request_uri = "/api"
        kong.service.request.set_header = function() end
        kong.service.request.clear_header = function() end
        kong.client.authenticate = function() end
        local config = mocks.make_config({ bearer_jwt_auth_enable = "yes" })

        handler:access(config)

        assert.is_true(jwt_verify_called)
        assert.is_false(authenticate_called)
      end)

      -- H-07
      it("JWT検証失敗の場合_イントロスペクションにフォールバックすること", function()
        ngx.req.get_headers = function()
          return { Authorization = "Bearer some-token" }
        end
        package.loaded["resty.openidc"].get_discovery_doc = function()
          return { issuer = "https://example.com" }, nil
        end
        package.loaded["resty.openidc"].bearer_jwt_verify = function()
          return nil, "JWT verify failed"
        end
        local introspect_called = false
        package.loaded["resty.openidc"].introspect = function()
          introspect_called = true
          return { sub = "u1", preferred_username = "user1", active = true }, nil
        end
        ngx.var.uri = "/api"
        ngx.var.request_uri = "/api"
        kong.service.request.set_header = function() end
        kong.service.request.clear_header = function() end
        kong.client.authenticate = function() end
        kong.log.err = function() end
        local config = mocks.make_config({
          bearer_jwt_auth_enable = "yes",
          introspection_endpoint = "https://example.com/introspect",
        })

        handler:access(config)

        assert.is_true(introspect_called)
      end)

      -- H-08
      it("イントロスペクションもnilの場合_make_oidcにフォールバックすること", function()
        -- Arrange: Bearer ヘッダーあり → JWT 検証失敗 → introspect もエラー → make_oidc
        ngx.req.get_headers = function()
          return { Authorization = "Bearer some-token" }
        end
        package.loaded["resty.openidc"].get_discovery_doc = function()
          return { issuer = "https://example.com" }, nil
        end
        package.loaded["resty.openidc"].bearer_jwt_verify = function()
          return nil, "JWT verify failed"
        end
        local introspect_called = false
        package.loaded["resty.openidc"].introspect = function()
          introspect_called = true
          return nil, "introspect failed"
        end
        local authenticate_called = false
        package.loaded["resty.openidc"].authenticate = function()
          authenticate_called = true
          return { user = { sub = "u1" }, id_token = { sub = "u1" }, access_token = "tok" }, nil
        end
        ngx.var.uri = "/api"
        ngx.var.request_uri = "/api"
        kong.log.err = function() end
        local config = mocks.make_config({
          bearer_jwt_auth_enable = "yes",
          introspection_endpoint = "https://example.com/introspect",
        })

        -- Act
        handler:access(config)

        -- Assert: introspect が呼ばれ、かつ make_oidc にフォールバック
        assert.is_true(introspect_called)
        assert.is_true(authenticate_called)
      end)

      -- H-08b
      it("Bearerトークンあり_JWT/イントロスペクション未設定_deny時_401が返されること", function()
        ngx.req.get_headers = function()
          return { Authorization = "Bearer some-token" }
        end
        local error_code
        kong.response.error = function(code) error_code = code end
        package.loaded["resty.openidc"].authenticate = function()
          return nil, "unauthorized request"
        end
        ngx.var.uri = "/api"
        ngx.var.request_uri = "/api"
        local config = mocks.make_config({ unauth_action = "deny" })

        handler:access(config)

        assert.are.equal(401, error_code)
      end)
    end)

    ---------------------------------------------------------------------------
    -- make_oidc (H-09 〜 H-15)
    ---------------------------------------------------------------------------
    describe("make_oidc", function()
      -- H-09
      it("Redis設定の場合_session_configにRedis情報が含まれること", function()
        local captured_session_config
        package.loaded["resty.openidc"].authenticate = function(_, _, _, session_config)
          captured_session_config = session_config
          return { user = { sub = "u1" }, id_token = { sub = "u1" }, access_token = "tok" }, nil
        end
        ngx.var.uri = "/api"
        ngx.var.request_uri = "/api"
        kong.service.request.set_header = function() end
        kong.service.request.clear_header = function() end
        kong.client.authenticate = function() end
        local config = mocks.make_config({
          session_storage    = "redis",
          session_redis_host = "redis-host",
          session_redis_port = 6380,
        })

        handler:access(config)

        assert.is_not_nil(captured_session_config)
        assert.are.equal("redis", captured_session_config.storage)
        assert.is_not_nil(captured_session_config.redis)
        assert.are.equal("redis-host", captured_session_config.redis.host)
        assert.are.equal(6380, captured_session_config.redis.port)
      end)

      -- H-10
      it("Cookie設定の場合_session_configにRedis情報が含まれないこと", function()
        local captured_session_config
        package.loaded["resty.openidc"].authenticate = function(_, _, _, session_config)
          captured_session_config = session_config
          return { user = { sub = "u1" }, id_token = { sub = "u1" }, access_token = "tok" }, nil
        end
        ngx.var.uri = "/api"
        ngx.var.request_uri = "/api"
        kong.service.request.set_header = function() end
        kong.service.request.clear_header = function() end
        kong.client.authenticate = function() end
        local config = mocks.make_config({ session_storage = "cookie" })

        handler:access(config)

        assert.is_not_nil(captured_session_config)
        assert.is_nil(captured_session_config.storage)
        assert.is_nil(captured_session_config.redis)
      end)

      -- H-11
      it("unauth_actionがdenyの場合_authenticateにdenyが渡されること", function()
        local captured_unauth_action
        package.loaded["resty.openidc"].authenticate = function(_, _, unauth_action)
          captured_unauth_action = unauth_action
          return { user = { sub = "u1" }, id_token = { sub = "u1" }, access_token = "tok" }, nil
        end
        ngx.var.uri = "/api"
        ngx.var.request_uri = "/api"
        kong.service.request.set_header = function() end
        kong.service.request.clear_header = function() end
        kong.client.authenticate = function() end
        local config = mocks.make_config({ unauth_action = "deny" })

        handler:access(config)

        assert.are.equal("deny", captured_unauth_action)
      end)

      -- H-12
      it("認証成功の場合_ヘッダー注入関数が呼ばれること", function()
        local headers_set = {}
        package.loaded["resty.openidc"].authenticate = function()
          return {
            user = { sub = "u1", preferred_username = "user1" },
            id_token = { sub = "u1", iss = "https://example.com" },
            access_token = "access-tok"
          }, nil
        end
        ngx.var.uri = "/api"
        ngx.var.request_uri = "/api"
        kong.service.request.set_header = function(name, value)
          headers_set[name] = value
        end
        kong.service.request.clear_header = function() end
        kong.client.authenticate = function() end
        local config = mocks.make_config()

        handler:access(config)

        assert.is_not_nil(headers_set["X-USERINFO"])
        assert.is_not_nil(headers_set["X-Access-Token"])
        assert.is_not_nil(headers_set["X-ID-Token"])
      end)

      -- H-12b
      it("認証成功でuser.groupsがある場合_user側のinjectGroupsが呼ばれること", function()
        package.loaded["resty.openidc"].authenticate = function()
          return {
            user = { sub = "u1", preferred_username = "user1", groups = { "admin" } },
            id_token = { sub = "u1", iss = "https://example.com" },
            access_token = "access-tok"
          }, nil
        end
        ngx.var.uri = "/api"
        ngx.var.request_uri = "/api"
        local config = mocks.make_config()

        handler:access(config)

        assert.are.same({ "admin" }, kong.ctx.shared.authenticated_groups)
      end)

      -- H-12c: issue #1 regression
      -- session_contents.user = false のとき response.user が nil になり、
      -- { response.user, response.id_token } が nil ホール付きテーブルリテラルになる。
      -- handler.lua の non_nil_sources ヘルパーで nil を除外し、id_token 側から
      -- header_claims を解決できることを検証する。
      it("response.userがnilでheader_claims設定ありの場合_id_tokenからクレームが解決されてクラッシュしないこと", function()
        local headers_set = {}
        package.loaded["resty.openidc"].authenticate = function()
          return {
            user = nil,
            id_token = {
              sub = "u1",
              iss = "https://example.com",
              email = "user@example.com",
              custom_claim_1 = "E12345",
            },
            access_token = "access-tok",
          }, nil
        end
        ngx.var.uri = "/api"
        ngx.var.request_uri = "/api"
        kong.service.request.set_header = function(name, value)
          headers_set[name] = value
        end
        kong.service.request.clear_header = function() end
        kong.client.authenticate = function() end
        local config = mocks.make_config({
          header_names  = { "X-User-EmployeeId", "X-User-Email" },
          header_claims = { "custom_claim_1", "email" },
        })

        assert.has_no.errors(function()
          handler:access(config)
        end)

        assert.are.equal("E12345", headers_set["X-User-EmployeeId"])
        assert.are.equal("user@example.com", headers_set["X-User-Email"])
      end)

      -- H-13
      it("unauthorized_requestエラーの場合_401が返されること", function()
        package.loaded["resty.openidc"].authenticate = function()
          return nil, "unauthorized request"
        end
        local error_code
        kong.response.error = function(code) error_code = code end
        ngx.var.uri = "/api"
        ngx.var.request_uri = "/api"
        local config = mocks.make_config()

        handler:access(config)

        assert.are.equal(401, error_code)
      end)

      -- H-14
      it("recovery_page_path設定ありでエラーの場合_リダイレクトされること", function()
        package.loaded["resty.openidc"].authenticate = function()
          return nil, "some error"
        end
        local redirect_path
        ngx.redirect = function(path) redirect_path = path end
        kong.response.error = function() end
        ngx.var.uri = "/api"
        ngx.var.request_uri = "/api"
        local config = mocks.make_config({ recovery_page_path = "/error-page" })

        handler:access(config)

        assert.are.equal("/error-page", redirect_path)
      end)

      -- H-15
      it("recovery_page_path未設定でエラーの場合_500が返されること", function()
        package.loaded["resty.openidc"].authenticate = function()
          return nil, "some error"
        end
        local error_code
        kong.response.error = function(code) error_code = code end
        ngx.var.uri = "/api"
        ngx.var.request_uri = "/api"
        local config = mocks.make_config()

        handler:access(config)

        assert.are.equal(500, error_code)
      end)
    end)

    ---------------------------------------------------------------------------
    -- introspect (H-16 〜 H-19)
    ---------------------------------------------------------------------------
    describe("introspect", function()
      local function setup_bearer_header()
        ngx.req.get_headers = function()
          return { Authorization = "Bearer some-token" }
        end
        ngx.var.uri = "/api"
        ngx.var.request_uri = "/api"
        kong.service.request.set_header = function() end
        kong.service.request.clear_header = function() end
        kong.client.authenticate = function() end
      end

      -- H-16
      it("use_jwks有効の場合_bearer_jwt_verifyが呼ばれること", function()
        setup_bearer_header()
        local jwt_verify_called = false
        package.loaded["resty.openidc"].bearer_jwt_verify = function()
          jwt_verify_called = true
          return { sub = "u1", preferred_username = "user1", active = true }, nil
        end
        local introspect_called = false
        package.loaded["resty.openidc"].introspect = function()
          introspect_called = true
          return {}, nil
        end
        local config = mocks.make_config({
          introspection_endpoint = "https://example.com/introspect",
          use_jwks = "yes",
        })

        handler:access(config)

        assert.is_true(jwt_verify_called)
        assert.is_false(introspect_called)
      end)

      -- H-17
      it("validate_scope有効でスコープ一致の場合_成功すること", function()
        setup_bearer_header()
        package.loaded["resty.openidc"].introspect = function()
          return { sub = "u1", preferred_username = "user1", scope = "openid profile" }, nil
        end
        local error_called = false
        kong.response.error = function() error_called = true end
        local config = mocks.make_config({
          introspection_endpoint = "https://example.com/introspect",
          validate_scope = "yes",
          scope = "openid",
        })

        handler:access(config)

        assert.is_false(error_called)
      end)

      -- H-18
      it("スコープ不一致の場合_403が返されること", function()
        setup_bearer_header()
        package.loaded["resty.openidc"].introspect = function()
          return { sub = "u1", scope = "other" }, nil
        end
        local error_code
        kong.response.error = function(code) error_code = code end
        kong.log.err = function() end
        local config = mocks.make_config({
          introspection_endpoint = "https://example.com/introspect",
          validate_scope = "yes",
          scope = "openid",
        })

        handler:access(config)

        assert.are.equal(403, error_code)
      end)

      -- H-18a: issue #5 regression
      -- 複数の必須スコープがすべてトークンに含まれる場合は成功する
      it("validate_scope有効で複数必須スコープがすべてトークンに含まれる場合_成功すること", function()
        setup_bearer_header()
        package.loaded["resty.openidc"].introspect = function()
          return { sub = "u1", preferred_username = "user1", scope = "openid profile email" }, nil
        end
        local error_called = false
        kong.response.error = function() error_called = true end
        local config = mocks.make_config({
          introspection_endpoint = "https://example.com/introspect",
          validate_scope = "yes",
          scope = "openid profile",
        })

        handler:access(config)

        assert.is_false(error_called)
      end)

      -- H-18c: issue #5 regression
      -- 複数の必須スコープのうち一部しかトークンに含まれない場合は 403
      it("validate_scope有効で必須スコープが一部不足する場合_403が返されること", function()
        setup_bearer_header()
        package.loaded["resty.openidc"].introspect = function()
          return { sub = "u1", scope = "openid" }, nil
        end
        local error_code
        kong.response.error = function(code) error_code = code end
        kong.log.err = function() end
        local config = mocks.make_config({
          introspection_endpoint = "https://example.com/introspect",
          validate_scope = "yes",
          scope = "openid profile",
        })

        handler:access(config)

        assert.are.equal(403, error_code)
      end)

      -- H-18d: issue #5 regression
      -- res.scope が nil の場合は 403
      it("validate_scope有効でres_scopeがnilの場合_403が返されること", function()
        setup_bearer_header()
        package.loaded["resty.openidc"].introspect = function()
          return { sub = "u1" }, nil
        end
        local error_code
        kong.response.error = function(code) error_code = code end
        kong.log.err = function() end
        local config = mocks.make_config({
          introspection_endpoint = "https://example.com/introspect",
          validate_scope = "yes",
          scope = "openid",
        })

        handler:access(config)

        assert.are.equal(403, error_code)
      end)

      -- H-18b
      it("Bearerトークンなし_bearer_onlyでもない場合_nilが返されること", function()
        ngx.req.get_headers = function() return {} end
        local authenticate_called = false
        package.loaded["resty.openidc"].authenticate = function()
          authenticate_called = true
          return { user = { sub = "u1" }, id_token = { sub = "u1" }, access_token = "tok" }, nil
        end
        ngx.var.uri = "/api"
        ngx.var.request_uri = "/api"
        local config = mocks.make_config({
          introspection_endpoint = "https://example.com/introspect",
          bearer_only = "no",
        })

        handler:access(config)

        -- introspect が nil を返し make_oidc にフォールバック
        assert.is_true(authenticate_called)
      end)

      -- H-19
      it("bearer_onlyでエラーの場合_401とWWW-Authenticateヘッダーが返されること", function()
        setup_bearer_header()
        package.loaded["resty.openidc"].introspect = function()
          return nil, "token expired"
        end
        local error_code
        kong.response.error = function(code) error_code = code end
        local config = mocks.make_config({
          introspection_endpoint = "https://example.com/introspect",
          bearer_only = "yes",
        })

        handler:access(config)

        assert.are.equal(401, error_code)
        assert.truthy(ngx.header["WWW-Authenticate"])
        assert.truthy(ngx.header["WWW-Authenticate"]:find("Bearer realm="))
      end)
    end)

    ---------------------------------------------------------------------------
    -- verify_bearer_jwt (H-20 〜 H-24)
    ---------------------------------------------------------------------------
    describe("verify_bearer_jwt", function()
      -- H-20
      it("Bearerトークンなしの場合_nilが返されること", function()
        ngx.req.get_headers = function() return {} end
        local authenticate_called = false
        package.loaded["resty.openidc"].authenticate = function()
          authenticate_called = true
          return { user = { sub = "u1" }, id_token = { sub = "u1" }, access_token = "tok" }, nil
        end
        ngx.var.uri = "/api"
        ngx.var.request_uri = "/api"
        kong.service.request.set_header = function() end
        kong.service.request.clear_header = function() end
        kong.client.authenticate = function() end
        local config = mocks.make_config({ bearer_jwt_auth_enable = "yes" })

        handler:access(config)

        -- Bearer なしなので JWT verify はスキップされ、make_oidc にフォールバック
        assert.is_true(authenticate_called)
      end)

      -- H-21
      it("正常トークンの場合_検証結果が返されること", function()
        ngx.req.get_headers = function()
          return { Authorization = "Bearer valid-jwt" }
        end
        local credentials_set = false
        kong.client.authenticate = function() credentials_set = true end
        kong.service.request.set_header = function() end
        kong.service.request.clear_header = function() end
        package.loaded["resty.openidc"].get_discovery_doc = function()
          return { issuer = "https://example.com" }, nil
        end
        package.loaded["resty.openidc"].bearer_jwt_verify = function()
          return { sub = "u1", preferred_username = "user1" }, nil
        end
        local authenticate_called = false
        package.loaded["resty.openidc"].authenticate = function()
          authenticate_called = true
          return {}, nil
        end
        ngx.var.uri = "/api"
        ngx.var.request_uri = "/api"
        local config = mocks.make_config({ bearer_jwt_auth_enable = "yes" })

        handler:access(config)

        assert.is_true(credentials_set)
        assert.is_false(authenticate_called)
      end)

      -- H-22
      it("allowed_auds設定の場合_client_idの代わりに使用されること", function()
        ngx.req.get_headers = function()
          return { Authorization = "Bearer valid-jwt" }
        end
        kong.client.authenticate = function() end
        kong.service.request.set_header = function() end
        kong.service.request.clear_header = function() end
        package.loaded["resty.openidc"].get_discovery_doc = function()
          return { issuer = "https://example.com" }, nil
        end
        local captured_claim_spec
        package.loaded["resty.openidc"].bearer_jwt_verify = function(_, claim_spec)
          captured_claim_spec = claim_spec
          return { sub = "u1", preferred_username = "user1" }, nil
        end
        ngx.var.uri = "/api"
        ngx.var.request_uri = "/api"
        local config = mocks.make_config({
          bearer_jwt_auth_enable = "yes",
          bearer_jwt_auth_allowed_auds = { "custom-aud-1", "custom-aud-2" },
        })

        handler:access(config)

        assert.is_not_nil(captured_claim_spec)
        assert.is_not_nil(captured_claim_spec.aud)
        -- aud バリデータは has_common_item を使うので、allowed_auds に含まれる値で true を返す
        assert.is_truthy(captured_claim_spec.aud("custom-aud-1"))
        assert.is_falsy(captured_claim_spec.aud("unknown-aud"))
      end)

      -- H-23
      it("ディスカバリ失敗の場合_nilが返されること", function()
        ngx.req.get_headers = function()
          return { Authorization = "Bearer valid-jwt" }
        end
        package.loaded["resty.openidc"].get_discovery_doc = function()
          return nil, "discovery failed"
        end
        kong.log.err = function() end
        local authenticate_called = false
        package.loaded["resty.openidc"].authenticate = function()
          authenticate_called = true
          return { user = { sub = "u1" }, id_token = { sub = "u1" }, access_token = "tok" }, nil
        end
        ngx.var.uri = "/api"
        ngx.var.request_uri = "/api"
        kong.service.request.set_header = function() end
        kong.service.request.clear_header = function() end
        kong.client.authenticate = function() end
        local config = mocks.make_config({ bearer_jwt_auth_enable = "yes" })

        handler:access(config)

        -- discovery 失敗 → verify_bearer_jwt が nil → make_oidc にフォールバック
        assert.is_true(authenticate_called)
      end)

      -- H-24
      it("検証失敗の場合_nilが返されログ出力されること", function()
        ngx.req.get_headers = function()
          return { Authorization = "Bearer invalid-jwt" }
        end
        package.loaded["resty.openidc"].get_discovery_doc = function()
          return { issuer = "https://example.com" }, nil
        end
        package.loaded["resty.openidc"].bearer_jwt_verify = function()
          return nil, "JWT signature verification failed"
        end
        local err_logged = false
        kong.log.err = function() err_logged = true end
        local authenticate_called = false
        package.loaded["resty.openidc"].authenticate = function()
          authenticate_called = true
          return { user = { sub = "u1" }, id_token = { sub = "u1" }, access_token = "tok" }, nil
        end
        ngx.var.uri = "/api"
        ngx.var.request_uri = "/api"
        kong.service.request.set_header = function() end
        kong.service.request.clear_header = function() end
        kong.client.authenticate = function() end
        local config = mocks.make_config({ bearer_jwt_auth_enable = "yes" })

        handler:access(config)

        assert.is_true(err_logged)
        assert.is_true(authenticate_called)
      end)
    end)
  end)
end)

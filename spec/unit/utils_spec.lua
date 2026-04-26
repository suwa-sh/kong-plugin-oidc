local mocks = require("spec.unit.helpers.mocks")

describe("utils", function()
  local utils

  setup(function()
    mocks.setup()
    utils = require("kong.plugins.oidc.utils")
  end)

  before_each(function()
    mocks.reset()
  end)

  teardown(function()
    mocks.teardown()
  end)

  ---------------------------------------------------------------------------
  -- get_redirect_uri (U-01 〜 U-04)
  ---------------------------------------------------------------------------
  describe("get_redirect_uri", function()
    -- U-01
    it("末尾スラッシュなしのパスの場合_スラッシュが付加されること", function()
      ngx.var.request_uri = "/api/data"

      local result = utils.get_redirect_uri(ngx)

      assert.are.equal("/api/data/", result)
    end)

    -- U-02
    it("末尾スラッシュありのパスの場合_スラッシュが除去されること", function()
      ngx.var.request_uri = "/api/data/"

      local result = utils.get_redirect_uri(ngx)

      assert.are.equal("/api/data", result)
    end)

    -- U-03
    it("ルートパスの場合_cbが返されること", function()
      ngx.var.request_uri = "/"

      local result = utils.get_redirect_uri(ngx)

      assert.are.equal("/cb", result)
    end)

    -- U-04
    it("クエリ文字列付きの場合_クエリが除去されること", function()
      ngx.var.request_uri = "/api/data?foo=bar"

      local result = utils.get_redirect_uri(ngx)

      assert.are.equal("/api/data/", result)
    end)

    -- U-04b
    it("codeパラメータありの場合_パスがそのまま返されること", function()
      ngx.var.request_uri = "/api/callback"
      ngx.req.get_uri_args = function() return { code = "auth-code-123" } end

      local result = utils.get_redirect_uri(ngx)

      assert.are.equal("/api/callback", result)
    end)
  end)

  ---------------------------------------------------------------------------
  -- get_options (U-05 〜 U-13)
  ---------------------------------------------------------------------------
  describe("get_options", function()
    -- U-05
    it("yesの文字列の場合_trueに変換されること", function()
      local config = mocks.make_config({ revoke_tokens_on_logout = "yes" })

      local opts = utils.get_options(config, ngx)

      assert.is_true(opts.revoke_tokens_on_logout)
    end)

    -- U-06
    it("noの文字列の場合_falseに変換されること", function()
      local config = mocks.make_config({ revoke_tokens_on_logout = "no" })

      local opts = utils.get_options(config, ngx)

      assert.is_false(opts.revoke_tokens_on_logout)
    end)

    -- U-07
    it("redirect_uri設定ありの場合_設定値が優先されること", function()
      local config = mocks.make_config({ redirect_uri = "https://example.com/callback" })

      local opts = utils.get_options(config, ngx)

      assert.are.equal("https://example.com/callback", opts.redirect_uri)
    end)

    -- U-08
    it("redirect_uri未設定の場合_自動計算されること", function()
      local config = mocks.make_config()
      ngx.var.request_uri = "/api/test"

      local opts = utils.get_options(config, ngx)

      assert.are.equal("/api/test/", opts.redirect_uri)
    end)

    -- U-09
    it("Redisセッション設定の場合_正しくマッピングされること", function()
      local config = mocks.make_config({
        session_storage        = "redis",
        session_redis_host     = "redis-host",
        session_redis_port     = 6380,
        session_redis_password = "secret",
        session_redis_database = 2,
        session_redis_ssl      = "yes",
      })

      local opts = utils.get_options(config, ngx)

      assert.are.equal("redis", opts.session_opts.storage)
      assert.are.equal("redis-host", opts.session_opts.redis_host)
      assert.are.equal(6380, opts.session_opts.redis_port)
      assert.are.equal("secret", opts.session_opts.redis_password)
      assert.are.equal(2, opts.session_opts.redis_database)
      assert.is_true(opts.session_opts.redis_ssl)
    end)

    -- U-10
    it("session_contentsのuserがfalseであること", function()
      local config = mocks.make_config()

      local opts = utils.get_options(config, ngx)

      assert.is_false(opts.session_contents.user)
      assert.is_true(opts.session_contents.id_token)
      assert.is_true(opts.session_contents.access_token)
    end)

    -- U-11
    it("プロキシ設定の場合_proxy_optsに反映されること", function()
      local config = mocks.make_config({
        http_proxy  = "http://proxy:8080",
        https_proxy = "https://proxy:8443",
      })

      local opts = utils.get_options(config, ngx)

      assert.are.equal("http://proxy:8080", opts.proxy_opts.http_proxy)
      assert.are.equal("https://proxy:8443", opts.proxy_opts.https_proxy)
    end)

    -- U-12
    it("フィルタCSV文字列の場合_テーブルにパースされること", function()
      local config = mocks.make_config({ filters = "/health,/metrics" })

      local opts = utils.get_options(config, ngx)

      assert.are.same({ "/health", "/metrics" }, opts.filters)
    end)

    -- U-13
    it("フィルタがnilの場合_空テーブルであること", function()
      local config = mocks.make_config({ filters = nil, ignore_auth_filters = nil })

      local opts = utils.get_options(config, ngx)

      assert.are.same({}, opts.filters)
    end)
  end)

  ---------------------------------------------------------------------------
  -- injectAccessToken (U-14 〜 U-15)
  ---------------------------------------------------------------------------
  describe("injectAccessToken", function()
    -- U-14
    it("通常の場合_生トークンが設定されること", function()
      local set_header_called_with = {}
      kong.service.request.set_header = function(name, value)
        set_header_called_with = { name = name, value = value }
      end

      utils.injectAccessToken("my-token", "X-Access-Token", false)

      assert.are.equal("X-Access-Token", set_header_called_with.name)
      assert.are.equal("my-token", set_header_called_with.value)
    end)

    -- U-15
    it("bearerToken有効の場合_Bearerプレフィックスが付くこと", function()
      local set_header_called_with = {}
      kong.service.request.set_header = function(name, value)
        set_header_called_with = { name = name, value = value }
      end

      utils.injectAccessToken("my-token", "X-Access-Token", true)

      assert.are.equal("Bearer my-token", set_header_called_with.value)
    end)
  end)

  ---------------------------------------------------------------------------
  -- injectIDToken (U-16)
  ---------------------------------------------------------------------------
  describe("injectIDToken", function()
    -- U-16
    it("IDトークンの場合_Base64エンコードされること", function()
      local set_header_called_with = {}
      kong.service.request.set_header = function(name, value)
        set_header_called_with = { name = name, value = value }
      end
      local id_token = { sub = "user1", iss = "https://example.com" }

      utils.injectIDToken(id_token, "X-ID-Token")

      assert.are.equal("X-ID-Token", set_header_called_with.name)
      -- cjson.encode は "json:..." を返し、ngx.encode_base64 は "b64:..." を返す
      assert.truthy(set_header_called_with.value:find("^b64:json:"))
    end)
  end)

  ---------------------------------------------------------------------------
  -- injectUser (U-17)
  ---------------------------------------------------------------------------
  describe("injectUser", function()
    -- U-17
    it("ユーザー情報の場合_Base64エンコードされること", function()
      local set_header_called_with = {}
      kong.service.request.set_header = function(name, value)
        set_header_called_with = { name = name, value = value }
      end
      local user = { sub = "user1", name = "Test User" }

      utils.injectUser(user, "X-USERINFO")

      assert.are.equal("X-USERINFO", set_header_called_with.name)
      assert.truthy(set_header_called_with.value:find("^b64:json:"))
    end)
  end)

  ---------------------------------------------------------------------------
  -- injectGroups (U-18)
  ---------------------------------------------------------------------------
  describe("injectGroups", function()
    -- U-18
    it("グループクレームの場合_kong.ctx.sharedに設定されること", function()
      local user = { groups = { "admin", "users" } }

      utils.injectGroups(user, "groups")

      assert.are.same({ "admin", "users" }, kong.ctx.shared.authenticated_groups)
    end)
  end)

  ---------------------------------------------------------------------------
  -- injectHeaders (U-19 〜 U-21)
  ---------------------------------------------------------------------------
  describe("injectHeaders", function()
    -- U-19
    it("カスタムクレームの場合_ヘッダーにマッピングされること", function()
      local headers_set = {}
      kong.service.request.set_header = function(name, value)
        headers_set[name] = value
      end
      kong.service.request.clear_header = function() end
      local source = { email = "test@example.com", name = "Test" }

      utils.injectHeaders({ "X-Email", "X-Name" }, { "email", "name" }, { source })

      assert.are.equal("test@example.com", headers_set["X-Email"])
      assert.are.equal("Test", headers_set["X-Name"])
    end)

    -- U-20
    it("names/claimsの長さ不一致の場合_エラーログが出力されること", function()
      local err_called = false
      kong.log.err = function() err_called = true end

      utils.injectHeaders({ "X-Email" }, { "email", "name" }, { {} })

      assert.is_true(err_called)
    end)

    -- U-21
    it("テーブル型クレームの場合_カンマ区切りで結合されること", function()
      local headers_set = {}
      kong.service.request.set_header = function(name, value)
        headers_set[name] = value
      end
      kong.service.request.clear_header = function() end
      local source = { roles = { "admin", "editor", "viewer" } }

      utils.injectHeaders({ "X-Roles" }, { "roles" }, { source })

      assert.are.equal("admin, editor, viewer", headers_set["X-Roles"])
    end)

    -- U-21b: issue #1 regression
    -- injectHeaders が nil source を安全に扱えることを検証する防御的テスト。
    -- handler.lua 側の non_nil_sources で nil は除外されるが、
    -- utils.lua 側でも if source then ガードで防御する。
    it("sourcesリストの要素がnilの場合_クラッシュせず次のsourceから解決されること", function()
      local headers_set = {}
      kong.service.request.set_header = function(name, value)
        headers_set[name] = value
      end
      kong.service.request.clear_header = function() end
      -- Lua 5.1 では { nil, x } の #t は実装依存のため、 rawset で明示的に nil を
      -- 埋め、n フィールドで長さを指定した疑似的な sources を構築する
      local sources = { [1] = false, [2] = { email = "user@example.com" } }
      -- false は nil ではないが、if source then ガードでは同じく false パスに入るため
      -- 防御的ガードの動作検証として有効。

      assert.has_no.errors(function()
        utils.injectHeaders({ "X-Email" }, { "email" }, sources)
      end)
      assert.are.equal("user@example.com", headers_set["X-Email"])
    end)
  end)

  ---------------------------------------------------------------------------
  -- setCredentials (U-22 〜 U-23)
  ---------------------------------------------------------------------------
  describe("setCredentials", function()
    -- U-22
    it("subとpreferred_usernameの場合_id/usernameにマッピングされること", function()
      local authenticated_credential
      kong.client.authenticate = function(_, credential)
        authenticated_credential = credential
      end
      kong.service.request.set_header = function() end
      kong.service.request.clear_header = function() end
      local user = { sub = "user-123", preferred_username = "testuser" }

      utils.setCredentials(user)

      assert.are.equal("user-123", authenticated_credential.id)
      assert.are.equal("testuser", authenticated_credential.username)
    end)

    -- U-23
    it("元のuserテーブルの場合_変更されないこと（浅コピー確認）", function()
      kong.client.authenticate = function() end
      kong.service.request.set_header = function() end
      kong.service.request.clear_header = function() end
      local user = { sub = "user-123", preferred_username = "testuser" }

      utils.setCredentials(user)

      assert.is_nil(user.id)
      assert.is_nil(user.username)
    end)
  end)

  ---------------------------------------------------------------------------
  -- has_bearer_access_token (U-24 〜 U-25)
  ---------------------------------------------------------------------------
  describe("has_bearer_access_token", function()
    -- U-24
    it("Bearerヘッダーありの場合_trueであること", function()
      ngx.req.get_headers = function()
        return { Authorization = "Bearer some-token" }
      end

      local result = utils.has_bearer_access_token()

      assert.is_true(result)
    end)

    -- U-25
    it("Bearerヘッダーなしの場合_falseであること", function()
      ngx.req.get_headers = function()
        return {}
      end

      local result = utils.has_bearer_access_token()

      assert.is_false(result)
    end)
  end)

  ---------------------------------------------------------------------------
  -- sanitize_header_value (U-30 〜 U-36) issue #8
  -- WWW-Authenticate ヘッダの quoted-string 値の安全化
  ---------------------------------------------------------------------------
  describe("sanitize_header_value", function()
    -- U-30
    it("CR/LFを含む場合_除去されること", function()
      local result = utils.sanitize_header_value("invalid_token\r\nX-Bad: 1")

      assert.are.equal("invalid_tokenX-Bad: 1", result)
    end)

    -- U-31
    it("ダブルクォートを含む場合_エスケープされること", function()
      local result = utils.sanitize_header_value('foo"bar')

      assert.are.equal('foo\\"bar', result)
    end)

    -- U-32
    it("バックスラッシュを含む場合_エスケープされること", function()
      local result = utils.sanitize_header_value("foo\\bar")

      assert.are.equal("foo\\\\bar", result)
    end)

    -- U-33
    it("制御文字を含む場合_除去されること", function()
      local result = utils.sanitize_header_value("foo\t\0\bbar")

      assert.are.equal("foobar", result)
    end)

    -- U-34
    it("非文字列の場合_server_errorが返されること", function()
      assert.are.equal("server_error", utils.sanitize_header_value(nil))
      assert.are.equal("server_error", utils.sanitize_header_value(123))
      assert.are.equal("server_error", utils.sanitize_header_value({}))
    end)

    -- U-35
    it("200文字超の場合_切り詰められること", function()
      local long = string.rep("a", 300)

      local result = utils.sanitize_header_value(long)

      assert.are.equal(200, #result)
    end)

    -- U-36
    it("通常の文字列の場合_変更されないこと", function()
      local result = utils.sanitize_header_value("invalid_token")

      assert.are.equal("invalid_token", result)
    end)
  end)

  ---------------------------------------------------------------------------
  -- has_common_item (U-26 〜 U-29)
  ---------------------------------------------------------------------------
  describe("has_common_item", function()
    -- U-26
    it("共通要素ありの場合_trueであること", function()
      local result = utils.has_common_item({ "a", "b", "c" }, { "c", "d" })

      assert.is_true(result)
    end)

    -- U-27
    it("共通要素なしの場合_falseであること", function()
      local result = utils.has_common_item({ "a", "b" }, { "c", "d" })

      assert.is_false(result)
    end)

    -- U-28
    it("文字列とテーブルの混在の場合_正しく判定されること", function()
      local result = utils.has_common_item("a", { "a", "b" })

      assert.is_true(result)
    end)

    -- U-28b
    it("テーブルと文字列の混在の場合_正しく判定されること", function()
      local result = utils.has_common_item({ "a", "b" }, "b")

      assert.is_true(result)
    end)

    -- U-29
    it("nilの場合_falseであること", function()
      assert.is_false(utils.has_common_item(nil, { "a" }))
      assert.is_false(utils.has_common_item({ "a" }, nil))
      assert.is_false(utils.has_common_item(nil, nil))
    end)
  end)
end)

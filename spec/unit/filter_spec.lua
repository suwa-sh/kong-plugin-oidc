local mocks = require("spec.unit.helpers.mocks")

describe("shouldProcessRequest", function()
  local filter

  setup(function()
    mocks.setup()
    filter = require("kong.plugins.oidc.filter")
  end)

  before_each(function()
    mocks.reset()
  end)

  teardown(function()
    mocks.teardown()
  end)

  -- F-01
  it("フィルタ未設定の場合_trueであること", function()
    ngx.var.uri = "/any/path"

    local result = filter.shouldProcessRequest({})

    assert.is_true(result)
  end)

  -- F-02
  it("URIがフィルタに一致しない場合_trueであること", function()
    ngx.var.uri = "/api/data"

    local result = filter.shouldProcessRequest({ filters = { "/health" } })

    assert.is_true(result)
  end)

  -- F-03
  it("URIがフィルタに一致する場合_falseであること", function()
    ngx.var.uri = "/health"

    local result = filter.shouldProcessRequest({ filters = { "/health" } })

    assert.is_false(result)
  end)

  -- F-04
  it("複数フィルタの最後に一致する場合_falseであること", function()
    ngx.var.uri = "/health"

    local result = filter.shouldProcessRequest({ filters = { "/api", "/metrics", "/health" } })

    assert.is_false(result)
  end)

  -- F-05
  it("filtersが空テーブルの場合_trueであること", function()
    ngx.var.uri = "/any"

    local result = filter.shouldProcessRequest({ filters = {} })

    assert.is_true(result)
  end)

  -- F-06
  it("filtersがnilの場合_trueであること", function()
    ngx.var.uri = "/any"

    local result = filter.shouldProcessRequest({ filters = nil })

    assert.is_true(result)
  end)

  -- F-07
  it("Luaマ���ック文字を含むパターンの場���_string.findの動作に従うこと", function()
    -- Arrange
    -- "." は Lua パターンでは任意の1文字にマッチする
    -- "/api/v1.0" は "/api/v1x0" にもマッチする（リテラルならマッチしない）
    ngx.var.uri = "/api/v1x0/data"

    -- Act
    local result = filter.shouldProcessRequest({ filters = { "/api/v1.0" } })

    -- Assert
    assert.is_false(result)
  end)
end)

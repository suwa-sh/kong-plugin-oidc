local mocks = require("spec.unit.helpers.mocks")

describe("schema", function()
  local schema

  setup(function()
    mocks.setup()
    package.loaded["kong.plugins.oidc.schema"] = nil
    schema = require("kong.plugins.oidc.schema")
  end)

  teardown(function()
    package.loaded["kong.plugins.oidc.schema"] = nil
    mocks.teardown()
  end)

  -- 名前で config の field 定義を引き当てる
  local function find_field(name)
    for _, entry in ipairs(schema.fields) do
      if entry.config then
        for _, field_entry in ipairs(entry.config.fields) do
          local field_name, field_def = next(field_entry)
          if field_name == name then
            return field_def
          end
        end
      end
    end
    return nil
  end

  ---------------------------------------------------------------------------
  -- secret 系フィールドが encrypted / referenceable 属性を持つこと
  ---------------------------------------------------------------------------
  describe("secret fields", function()
    -- S-01
    it("client_secret_スキーマ定義_encryptedとreferenceableがtrueであること", function()
      local field = find_field("client_secret")

      assert.is_not_nil(field)
      assert.is_true(field.required)
      assert.is_true(field.encrypted)
      assert.is_true(field.referenceable)
    end)

    -- S-02
    it("encryption_secret_スキーマ定義_encryptedとreferenceableがtrueであること", function()
      local field = find_field("encryption_secret")

      assert.is_not_nil(field)
      assert.is_true(field.required)
      assert.is_true(field.encrypted)
      assert.is_true(field.referenceable)
    end)

    -- S-03
    it("session_redis_password_スキーマ定義_encryptedとreferenceableがtrueであること", function()
      local field = find_field("session_redis_password")

      assert.is_not_nil(field)
      assert.is_true(field.encrypted)
      assert.is_true(field.referenceable)
    end)
  end)
end)

-- luacheck configuration for Kong OIDC plugin
std = "ngx_lua+busted"

-- Kong and OpenResty globals
globals = {
  "kong",
}

read_globals = {
  "ngx",
}

-- Ignore line length (Kong plugins tend to have long lines)
max_line_length = false

-- テストファイルでは ngx/kong の書き換えを許可
files["spec/**/*_spec.lua"] = {
  globals = { "ngx", "kong" },
}

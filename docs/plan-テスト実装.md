# テスト実装計画

> この文書はテスト実装（タスク7〜）の作業計画。実装完了後に削除する。
> テスト戦略（永続）は [test-strategy.md](test-strategy.md) を参照。

## 1. ディレクトリ構成

```
spec/
  unit/
    helpers/
      mocks.lua              -- 共有 ngx/kong モック
    filter_spec.lua
    utils_spec.lua
    handler_spec.lua
  integration/
    fixtures/
      discovery.json         -- モック OIDC ディスカバリドキュメント
      jwks.json              -- モック JWKS
      kong.yml               -- テスト用 Kong 宣言的設定
    docker-compose.test.yml
    plugin_lifecycle_spec.lua
    session_redis_spec.lua
    header_injection_spec.lua
  e2e/
    docker-compose.e2e.yml
    setup/
      keycloak-setup.sh      -- Keycloak 自動セットアップ
    test_auth_code_flow.sh
    test_bearer_jwt.sh
    test_session_timeout.sh
```

## 2. ユニットテストケース一覧

### filter_spec.lua（7件）

| ID | カテゴリ | テストケース名 | 期待結果 |
|----|---------|--------------|---------|
| F-01 | 正常 | shouldProcessRequest_フィルタ未設定の場合_trueであること | `true` |
| F-02 | 正常 | shouldProcessRequest_URIがフィルタに一致しない場合_trueであること | `true` |
| F-03 | 正常 | shouldProcessRequest_URIがフィルタに一致する場合_falseであること | `false` |
| F-04 | 正常 | shouldProcessRequest_複数フィルタの最後に一致する場合_falseであること | `false` |
| F-05 | 境界 | shouldProcessRequest_filtersが空テーブルの場合_trueであること | `true` |
| F-06 | 境界 | shouldProcessRequest_filtersがnilの場合_trueであること | `true` |
| F-07 | 境界 | shouldProcessRequest_Luaマジック文字を含むパターンの場合_string.findの動作に従うこと | パターン動作に依存 |

### utils_spec.lua（29件）

**get_redirect_uri:**
| ID | カテゴリ | テストケース名 |
|----|---------|--------------|
| U-01 | 正常 | get_redirect_uri_末尾スラッシュなしのパスの場合_スラッシュが付加されること |
| U-02 | 正常 | get_redirect_uri_末尾スラッシュありのパスの場合_スラッシュが除去されること |
| U-03 | 正常 | get_redirect_uri_ルートパスの場合_cbが返されること |
| U-04 | 正常 | get_redirect_uri_クエリ文字列付きの場合_クエリが除去されること |

**get_options:**
| ID | カテゴリ | テストケース名 |
|----|---------|--------------|
| U-05 | 正常 | get_options_yesの文字列の場合_trueに変換されること |
| U-06 | 正常 | get_options_noの文字列の場合_falseに変換されること |
| U-07 | 正常 | get_options_redirect_uri設定ありの場合_設定値が優先されること |
| U-08 | 正常 | get_options_redirect_uri未設定の場合_自動計算されること |
| U-09 | 正常 | get_options_Redisセッション設定の場合_正しくマッピングされること |
| U-10 | 正常 | get_options_session_contentsのuserがfalseであること |
| U-11 | 正常 | get_options_プロキシ設定の場合_proxy_optsに反映されること |
| U-12 | 正常 | get_options_フィルタCSV文字列の場合_テーブルにパースされること |
| U-13 | 境界 | get_options_フィルタがnilの場合_空テーブルであること |

**ヘッダー注入:**
| ID | カテゴリ | テストケース名 |
|----|---------|--------------|
| U-14 | 正常 | injectAccessToken_通常の場合_生トークンが設定されること |
| U-15 | 正常 | injectAccessToken_bearerToken有効の場合_Bearerプレフィックスが付くこと |
| U-16 | 正常 | injectIDToken_IDトークンの場合_Base64エンコードされること |
| U-17 | 正常 | injectUser_ユーザー情報の場合_Base64エンコードされること |
| U-18 | 正常 | injectGroups_グループクレームの場合_kong.ctx.sharedに設定されること |
| U-19 | 正常 | injectHeaders_カスタムクレームの場合_ヘッダーにマッピングされること |
| U-20 | 異常 | injectHeaders_names/claimsの長さ不一致の場合_エラーログが出力されること |
| U-21 | 正常 | injectHeaders_テーブル型クレームの場合_カンマ区切りで結合されること |

**setCredentials:**
| ID | カテゴリ | テストケース名 |
|----|---------|--------------|
| U-22 | 正常 | setCredentials_subとpreferred_usernameの場合_id/usernameにマッピングされること |
| U-23 | 正常 | setCredentials_元のuserテーブルの場合_変更されないこと（浅コピー確認） |

**ユーティリティ:**
| ID | カテゴリ | テストケース名 |
|----|---------|--------------|
| U-24 | 正常 | has_bearer_access_token_Bearerヘッダーありの場合_trueであること |
| U-25 | 正常 | has_bearer_access_token_Bearerヘッダーなしの場合_falseであること |
| U-26 | 正常 | has_common_item_共通要素ありの場合_trueであること |
| U-27 | 正常 | has_common_item_共通要素なしの場合_falseであること |
| U-28 | 境界 | has_common_item_文字列とテーブルの混在の場合_正しく判定されること |
| U-29 | 境界 | has_common_item_nilの場合_falseであること |

### handler_spec.lua（25件）

**configure:**
| ID | カテゴリ | テストケース名 |
|----|---------|--------------|
| H-01 | 正常 | configure_複数設定の場合_最も抑制的なログレベルが選択されること |
| H-02 | 境界 | configure_configs空の場合_エラーにならないこと |

**access:**
| ID | カテゴリ | テストケース名 |
|----|---------|--------------|
| H-03 | 正常 | access_skip_already_auth有効で認証済みの場合_処理をスキップすること |
| H-04 | 正常 | access_フィルタに一致する場合_処理をスキップすること |
| H-05 | 正常 | access_通常リクエストの場合_handleが呼ばれること |

**handle:**
| ID | カテゴリ | テストケース名 |
|----|---------|--------------|
| H-06 | 正常 | handle_bearer_jwt有効の場合_verify_bearer_jwtが最初に呼ばれること |
| H-07 | 正常 | handle_JWT検証失敗の場合_イントロスペクションにフォールバックすること |
| H-08 | 正常 | handle_イントロスペクションもnilの場合_make_oidcにフォールバックすること |
| H-08b | 正常 | handle_Bearerトークンあり_JWT/イントロスペクション未設定_deny時_401が返されること |

**make_oidc:**
| ID | カテゴリ | テストケース名 |
|----|---------|--------------|
| H-09 | 正常 | make_oidc_Redis設定の場合_session_configにRedis情報が含まれること |
| H-10 | 正常 | make_oidc_Cookie設定の場合_session_configにRedis情報が含まれないこと |
| H-11 | 正常 | make_oidc_unauth_actionがdenyの場合_authenticateにdenyが渡されること |
| H-12 | 正常 | make_oidc_認証成功の場合_ヘッダー注入関数が呼ばれること |
| H-13 | 異常 | make_oidc_unauthorized_requestエラーの場合_401が返されること |
| H-14 | 異常 | make_oidc_recovery_page_path設定ありでエラーの場合_リダイレクトされること |
| H-15 | 異常 | make_oidc_recovery_page_path未設定でエラーの場合_500が返されること |

**introspect:**
| ID | カテゴリ | テストケース名 |
|----|---------|--------------|
| H-16 | 正常 | introspect_use_jwks有効の場合_bearer_jwt_verifyが呼ばれること |
| H-17 | 正常 | introspect_validate_scope有効でスコープ一致の場合_成功すること |
| H-18 | 異常 | introspect_スコープ不一致の場合_403が返されること |
| H-19 | 異常 | introspect_bearer_onlyでエラーの場合_401とWWW-Authenticateヘッダーが返されること |

**verify_bearer_jwt:**
| ID | カテゴリ | テストケース名 |
|----|---------|--------------|
| H-20 | 正常 | verify_bearer_jwt_Bearerトークンなしの場合_nilが返されること |
| H-21 | 正常 | verify_bearer_jwt_正常トークンの場合_検証結果が返されること |
| H-22 | 正常 | verify_bearer_jwt_allowed_auds設定の場合_client_idの代わりに使用されること |
| H-23 | 異常 | verify_bearer_jwt_ディスカバリ失敗の場合_nilが返されること |
| H-24 | 異常 | verify_bearer_jwt_検証失敗の場合_nilが返されログ出力されること |

## 3. 統合テストケース一覧（15件）

| ID | カテゴリ | テストケース名 |
|----|---------|--------------|
| I-01 | 正常 | プラグインロード_有効な設定の場合_正常にロードされること |
| I-02 | 異常 | プラグインロード_必須フィールド欠落の場合_拒否されること |
| I-03 | 正常 | フィルタ_フィルタパスへのリクエストの場合_認証がバイパスされること |
| I-04 | 正常 | AuthCodeフロー_セッションなしの場合_302リダイレクトされること |
| I-05 | 正常 | Bearerトークン_正常JWTの場合_ヘッダー付きでプロキシされること |
| I-06 | 正常 | Redisセッション_Redis設定の場合_Redisにセッションが保存されること |
| I-07 | 非機能 | Cookieサイズ_Redis設定の場合_セッションIDのみであること |
| I-08 | 正常 | ヘッダー注入_認証成功の場合_X-USERINFO/X-Access-Token/X-ID-Tokenが設定されること |
| I-09 | 正常 | カスタムヘッダー_header_names/claims設定の場合_正しく注入されること |
| I-10 | 異常 | Redis接続断_Redis停止中の場合_グレースフルに処理されること |
| I-11 | 異常 | 不正Cookie_改ざんされたCookieの場合_再認証が発生すること |
| I-12 | 正常 | プラグインチェイン_skip_already_auth有効の場合_認証済みスキップされること |
| I-13 | 正常 | bearer_only_未認証の場合_401が返されること（リダイレクトなし） |
| I-14 | 正常 | unauth_action_deny設定の場合_401が返されること |
| I-15 | 正常 | ログレベル_複数インスタンスの場合_最も抑制的なレベルが選択されること |

## 4. E2E テストケース一覧（12件）

| ID | カテゴリ | テストケース名 |
|----|---------|--------------|
| E-01 | 正常 | AuthCodeフロー_初回アクセスの場合_Keycloak認証後にセッションが発行されること |
| E-02 | 正常 | セッション再利用_認証済みCookie付きの場合_リダイレクトなしでプロキシされること |
| E-03 | 正常 | Bearer JWT_直接アクセスグラントのトークンの場合_バックエンドにアクセスできること |
| E-04 | 正常 | イントロスペクション_introspection_endpoint設定の場合_トークン検証されること |
| E-05 | 正常 | ログアウト_logout_pathアクセスの場合_セッションが破棄されリダイレクトされること |
| E-06 | 正常 | スライディングウィンドウ_アクティビティありの場合_セッションが延長されること |
| E-07 | 正常 | 絶対タイムアウト_設定時間超過の場合_強制再認証されること |
| E-08 | 異常 | 期限切れJWT_expiredトークンの場合_401が返されること |
| E-09 | 異常 | 不正aud JWT_異なるaudのトークンの場合_拒否されること |
| E-10 | 非機能 | Cookieサイズ_Redis設定の場合_200バイト未満であること |
| E-11 | 異常 | コールバック_セッション状態なしの場合_再認証リダイレクトされること |
| E-12 | 異常 | コールバック_state不一致の場合_エラーが返されること |

## 5. CI/CD ワークフロー定義

ファイル: `.github/workflows/ci.yml`

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install luacheck
        run: sudo luarocks install luacheck
      - name: luacheck
        run: luacheck kong/
      - name: qlty
        uses: qltysh/qlty-action/check@main

  unit-test:
    runs-on: ubuntu-latest
    needs: [lint]
    steps:
      - uses: actions/checkout@v4
      - name: Install busted
        run: sudo luarocks install busted
      - name: Run unit tests
        run: busted spec/unit/

  integration-test:
    runs-on: ubuntu-latest
    needs: [lint, unit-test]
    steps:
      - uses: actions/checkout@v4
      - name: Start services
        run: docker compose -f spec/integration/docker-compose.test.yml up -d
      - name: Wait for services
        run: sleep 10
      - name: Run integration tests
        run: docker compose -f spec/integration/docker-compose.test.yml exec kong busted spec/integration/
      - name: Stop services
        run: docker compose -f spec/integration/docker-compose.test.yml down

  e2e-test:
    runs-on: ubuntu-latest
    needs: [integration-test]
    steps:
      - uses: actions/checkout@v4
      - name: Start full stack
        run: docker compose -f spec/e2e/docker-compose.e2e.yml up -d
      - name: Wait for Keycloak
        run: |
          timeout 120 bash -c 'until curl -sf http://localhost:8080/health/ready; do sleep 2; done'
      - name: Setup Keycloak
        run: bash spec/e2e/setup/keycloak-setup.sh
      - name: Run E2E tests
        run: bash spec/e2e/test_auth_code_flow.sh && bash spec/e2e/test_bearer_jwt.sh && bash spec/e2e/test_session_timeout.sh
      - name: Stop services
        run: docker compose -f spec/e2e/docker-compose.e2e.yml down

  build:
    runs-on: ubuntu-latest
    needs: [lint]
    steps:
      - uses: actions/checkout@v4
      - name: Build Docker image
        run: docker build -t kong:kong-oidc .
```

## 6. 実装優先順位

**Phase 1 - ユニットテスト（最高 ROI、インフラ不要）**
1. `spec/unit/helpers/mocks.lua` 共有モック作成
2. `filter_spec.lua` - 7件、最もシンプル、モック手法の検証
3. `utils_spec.lua` - 29件、純粋ロジック関数
4. `handler_spec.lua` - 25件、resty.openidc モック必要

**Phase 2 - 統合テスト（docker 必要）**
5. MockOP フィクスチャ作成
6. docker-compose.test.yml 構築
7. プラグインライフサイクル + Redis セッションテスト

**Phase 3 - E2E テスト（全スタック必要）**
8. docker-compose.e2e.yml + Keycloak 自動セットアップ
9. 認証フロー E2E スクリプト

**推奨**: タスク7は Phase 1（ユニットテスト）に集中。Phase 2, 3 は後続タスクとする。

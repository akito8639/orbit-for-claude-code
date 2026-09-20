# 一般公開に向けたチェックリスト

## 開発者側で必要な設定

### 1. 署名と公証（必須）
- Developer ID Application 証明書を発行し、Release 構成の `CODE_SIGN_IDENTITY` を "Developer ID Application" に変更
- `ENABLE_HARDENED_RUNTIME = YES`（公証の必須条件。`security` の起動と `~/.claude` の読み取りは Hardened Runtime でも動作）
- `xcrun notarytool submit` → `xcrun stapler staple` → DMG / zip
- App Store 配布は不可（サンドボックス必須のため、Claude Code のキーチェーン項目と `~/.claude` を読めない）

### 2. ハードコードの外出し
- （対応済み）チーム ID と App Group は `Config.xcconfig` に集約。entitlements は `$(APP_GROUP_ID)`、コードは署名済み entitlements から実行時に読む
  → ソース公開する場合は `Config.xcconfig` に `DEVELOPMENT_TEAM` / App Group を移し、README に置き換え手順を記載
- `ClaudeAPI.clientID` は Claude Code の OAuth クライアント ID。第三者アプリでのトークン更新は規約上グレー
  → 公開版では自動更新を削除するか、既定 OFF のまま免責を明記
- usage / profile エンドポイントは非公開 API で予告なく変わり得る旨を README に明記

### 3. ウィジェットを単独で動かす（強く推奨）
- ログイン時起動: `SMAppService.mainApp.register()` のトグルを設定に追加
- `keychain-access-groups` entitlement でアプリとウィジェットがキーチェーンを共有し、ウィジェット拡張が手動トークンで直接取得できるようにする（アプリ常駐が不要になる）

### 4. 体裁と初回体験
- アプリアイコン（Asset Catalog）。ウィジェットギャラリーにも使われる
- 初回起動で認証情報が無ければ「接続」タブを自動で開き、ターミナルで `claude` にログインする手順とウィジェット追加の手順を案内
- （対応済み）String Catalog で英語 / 日本語 / 簡体字中国語 / 韓国語に対応
- 名称は "○○ for Claude Code" の形にし、「Anthropic 非公式」を明記
- 更新手段: GitHub Releases または Sparkle。Homebrew Cask があると導入が楽

### 5. プラン差への対応
- Pro では Opus 別枠が返らない、Team / Enterprise では usage エンドポイントが使えない場合がある
- 取得できない枠は非表示、エラー時は「Max / Pro の OAuth ログインが必要」と案内
- 取得間隔は 1 分未満にできない制限を維持

### 6. プライバシー文書
- PRIVACY.md: トークンは Anthropic のエンドポイントにのみ送信、テレメトリなし、ローカルログは端末内で集計するだけ

## 利用者向けの使い方

1. 動作要件: macOS 26 以降、Claude Pro または Max プラン
2. インストール: DMG からアプリケーションフォルダへ。初回起動で「ログイン時に起動」を ON
3. トークン設定
   - ターミナルで `claude` を使っていれば自動検出。キーチェーンの許可ダイアログは「常に許可」
   - 期限切れが出る場合はターミナルで `claude` を一度起動してログインし直す（`claude setup-token` のトークンはスコープ不足で使えない）
4. ウィジェットの追加: デスクトップ右クリック → 「ウィジェットを編集…」→ 検索 → Small / Medium / Large を配置
5. 表示の調整: メニューバーの ✱ → 歯車。表示項目の ON/OFF、デザイン、取得間隔、日本語ラベル
6. トラブル
   - "token expired": ターミナルで `claude` を起動してログインし直す
   - ウィジェットが更新されない: アプリが起動しているか確認

## 優先順位

1. Developer ID 署名 + Hardened Runtime + 公証
2. ログイン時起動 + keychain-access-groups でウィジェット単独動作
3. （アイコン・多言語は対応済み）オンボーディング
4. xcconfig 化、PRIVACY.md、免責文
5. Sparkle / Homebrew Cask

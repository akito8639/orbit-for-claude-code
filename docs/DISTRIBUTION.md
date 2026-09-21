# 配布とリリース手順

## 現状（2026-09-21 時点）

| 項目 | 状態 |
|---|---|
| 署名 | Developer ID Application（Hardened Runtime 有効、`get-task-allow` なし） |
| 公証 | GitHub Actions（`release.yml`）で `notarytool` → ステープル。失敗時は公証ログを自動表示 |
| 配布 | GitHub Releases の zip ＋ Homebrew tap `akito8639/tap`（cask `orbit-for-claude-code`） |
| CI | push ごとに未署名ビルド（`build.yml`、macOS 26 ランナー） |
| 設定の外出し | `Config.xcconfig`（Team ID / App Group / バンドル ID 接頭辞）。コードは署名済み entitlements から App Group を読む |
| アイコン | Icon Composer 形式 `App/AppIcon.icon`（背景＋2 レイヤー） |
| 多言語 | String Catalog（英語 / 日本語 / 簡体字中国語 / 韓国語）。ウィジェットのみ英語固定の設定あり |
| 初回起動 | 使用量が無ければ設定を自動で開く |
| 自動更新 | Sparkle。Release の `appcast.xml`（`SPARKLE_PRIVATE_KEY` で署名）を 1 日 1 回確認 |
| ウィジェット単独取得 | 本体が共有したアクセストークンで、本体停止中も使用量と稼働状況を取得 |
| 通知 | しきい値超過 / セッションの入力待ち / Claude 障害 |

## リリース手順

1. `Orbit.xcodeproj` の `MARKETING_VERSION` を上げてコミット・push
2. タグを打つと Release ワークフローが署名・公証・zip・GitHub Release 作成まで行う

```bash
git tag v1.0.1 && git push origin v1.0.1
```

3. Release の `sha256.txt` の値で、`akito8639/homebrew-tap` の `Casks/orbit-for-claude-code.rb` の `version` と `sha256` を更新して push（このリポジトリの `homebrew/` は同じ内容のミラー）
4. 動作確認: `brew update && brew upgrade --cask orbit-for-claude-code`

必要な GitHub Secrets: `DEVELOPER_ID_P12`（.p12 の base64）、`DEVELOPER_ID_P12_PASSWORD`、`DEVELOPMENT_TEAM`、`NOTARY_APPLE_ID`（Developer Program に登録した Apple ID）、`NOTARY_PASSWORD`（App 用パスワード）、`SPARKLE_PRIVATE_KEY`（`generate_keys -x` で書き出した EdDSA 秘密鍵。対応する公開鍵は `App/Info.plist` の `SUPublicEDKey`）。

## つまずきやすい点

- 公証で 401「account does not exist」→ Apple ID が Developer Program のものと違う
- 公証で Invalid「requests get-task-allow」→ Release に `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` が要る（設定済み）
- 開発版とリリース版を入れ替えた直後にウィジェットが空になる → `killall chronod NotificationCenter` か、ウィジェットのサイズ変更・置き直し
- Homebrew の第三者 tap は初回に `brew trust akito8639/tap` が必要

## 今後の候補

- 中国語・韓国語のネイティブ校正
- ウィジェット単独でのトークン更新（現状は本体が更新したアクセストークンを共有。約 8 時間で期限切れ）

## 利用者向けの要点

- 動作要件: macOS 26 以降、Claude Pro / Max、Claude Code CLI でログイン済み
- 「token expired」→ ターミナルで `claude` を起動して `/login`（`ANTHROPIC_API_KEY` がある環境は `env -u ANTHROPIC_API_KEY claude`）。`claude setup-token` と API キーは使えない
- 非公式プロジェクト。usage / profile エンドポイントは非公開 API で、予告なく変わり得る

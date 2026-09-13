<p align="center">
  <img src="Resources/AppIcon.iconset/icon_256x256.png" width="128" alt="Claude AutoSwitch のアイコン">
</p>
<h1 align="center">Claude AutoSwitch</h1>
<p align="center">
  複数の Claude サブスクリプションを、ひとつの Claude Code で。上限が埋まるにつれてアカウントを<br>
  自動でローテーションし、全アカウントのクォータをひと目で確認できるメニューバーアプリです。
</p>
<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-000?logo=apple&logoColor=white">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <img alt="Node も CLI もインストール不要" src="https://img.shields.io/badge/runtime-none%20needed-2ea44f">
  <img alt="7 言語対応" src="https://img.shields.io/badge/languages-7-3b82f6">
  <a href="LICENSE"><img alt="MIT" src="https://img.shields.io/badge/license-MIT-lightgrey"></a>
</p>
<p align="center" data-readme-switcher>
  <a href="README.md">English</a> · <a href="README.ko.md">한국어</a> · 日本語 · <a href="README.zh-CN.md">简体中文</a> · <a href="README.de.md">Deutsch</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a>
</p>

<p align="center">
  <img src="docs/assets/menubar/menubar-item.png" width="440" alt="メニューバー項目: システム項目の隣に 3h18m 33%">
</p>
<p align="center">
  <img src="docs/assets/menubar/popover-dark.png" width="406" alt="ポップオーバー: アカウント表、全アカウントのバー、ルーティング、セッション、ローテーションログ">
</p>

## 問題

**$200 の Max プランひとつではもう足りないので、2 つ、3 つと契約しています。**<br>
その内側で何が起きているのか、見てみましょう。

#### Max プランを 2 つ持つフリーランサー

> 「毎日午後になると、同じ一行です。`You've hit your usage limit · resets at 4pm`。<br>
> ブラウザ、サインアウト、サインイン、ターミナルに戻って、どこまでやっていたか探す。」

一日に 2、3 回、1 回 5 分。<br>
月にすると半日が消えています。

#### アカウントスイッチャーを入れた人

> 「クリック 1 回分は省けます。でも、いつクリックするかは教えてくれません。<br>
> 上限は相変わらず自分で見張って、手で切り替えています。」

#### ローテーションする TUI を動かしている人

> 「切り替えは自動になりました。残量を見るのは自動ではありません。<br>
> 実際に作業しているターミナルの隣に、もう 1 つターミナルを開いて、もう 1 つコマンドを打つことになります。」

**「別に、こうすればいいのでは…」**

- **…アカウントを 2 つ使えば？** 使えます。ただし上限に達するたびに、切り替えるのはあなた自身です。
- **…スイッチャーアプリを入れれば？** 切り替えは 1 クリックに縮まります。いつ、どのアカウントに切り替えるかは、相変わらずあなた次第です。
- **…ローテーションする TUI を動かせば？** ローテーションはしてくれます。ただし使用量は、開きっぱなしにしておくターミナルの中です。

**心当たりはありませんか？**

- [ ] Max プランを 2 つ以上契約している。
- [ ] 上限のメッセージが出ると、そのままブラウザに向かっている。
- [ ] このターミナルがどのアカウントで動いているのか、ときどき忘れる。
- [ ] 残量を見るためだけにターミナルを開いている。
- [ ] 週次の上限に、毎回不意打ちを食らっている。

3 つ以上当てはまるなら、次のセクションはあなたのためのものです。

## 解決策

Claude AutoSwitch は、メニューバーを備えたローカルプロキシです。<br>
2 つ以上の Claude アカウントでサインインし、Claude Code を `http://127.0.0.1:10912` に向けます。<br>
すべてのリクエストは、まだ余裕のあるアカウントのトークンで送信されます。<br>
あるアカウントが 5 時間または週次の上限に達すると、次のリクエストは単に別のアカウントを使います。<br>
Claude Code がログアウトすることも、再起動することも、それに気づくこともありません。<br>
全アカウントのクォータはメニューバーに並んでいるので、確認のためだけにターミナルを開くことはありません。

これはアカウント*スイッチャー*ではなく、キーチェーンで何かを入れ替えることも、セッションを中断することもありません。<br>
ローテーションは上限に達する前にリクエスト単位で行われ、複数のターミナルが同時に別々のアカウントを使うこともできます。

## インストール

要件: macOS 14 Sonoma 以降と Claude Code。<br>
Node も npm パッケージも、ほかのプロキシもインストールする必要はありません。

### Homebrew

```sh
brew install --cask ParkSangGwon/tap/claude-autoswitch
```

インストール後に macOS がアプリを開かせない場合は、隔離フラグを外します: `xattr -dr com.apple.quarantine "/Applications/Claude AutoSwitch.app"`（下記の「このまま開く」でも構いません）。

### GitHub リリース

[最新リリース](https://github.com/ParkSangGwon/claude-account-autoswitch/releases/latest)から `Claude-AutoSwitch-vX.Y.Z.zip` をダウンロードします。<br>
展開して **Claude AutoSwitch.app** を `/Applications` にドラッグしてください。

### ソースから

```sh
git clone https://github.com/ParkSangGwon/claude-account-autoswitch
cd claude-account-autoswitch
make install          # builds dist/Claude AutoSwitch.app and copies it to /Applications
```

このアプリはアドホック署名のみで、公証（notarization）はされていません。<br>
初回起動時に macOS が開発元を確認できないと表示することがあります。<br>
**システム設定 → プライバシーとセキュリティ** を開いて **このまま開く** をクリックするか、アプリを右クリック → **開く** を選んでください。

## 3 ステップでセットアップ

1. **アカウントを追加する。** 設定 → アカウント → *アカウントを追加…*
   - ブラウザでサインインする。
   - ブラウザからこの Mac に到達できない場合はコードを貼り付ける。
   - Claude Code がすでに持っているログイン（キーチェーン）を読み込む。
2. **Claude Code をプロキシに向ける。** 設定 → プロキシに、コピーボタン付きでこの 1 行が表示されています:
   ```sh
   export ANTHROPIC_BASE_URL=http://127.0.0.1:10912
   ```
   シェルプロファイルに入れるか、*ターミナルで Claude Code を開く* を使ってください。
3. **ログイン時に起動をオンにする**（設定 → 一般）と、Claude Code があるところにはいつでもプロキシがあります。

セットアップはこれだけです。<br>
Claude Code のログインはそのままです。<br>
プロキシは送信時にトークンを差し替えるだけで、リクエストのほかの部分には手を触れません。

## できること

- **使用量として読めるメニューバー項目。**
  - `1h12m 42%` は全アカウントの 5 時間ウィンドウで、リセットまでの時間、次に使用量の順です。その下のバーは 5 時間と週次です。
  - バーがウィンドウより先行するとオレンジ、切り替えしきい値到達時や応答できるアカウントがないときは赤になります。
  - ローテーション時は 6 秒間 `→ par`、待ち受けが停止していると `—` になります。
- **全アカウントをひと目で。**
  - セッション、週次、モデルファミリー別（Fable、Sonnet）のバーと、それぞれの下の数値とリセット時刻。
  - ティア、優先度、制限のカウントダウン、そのアカウントに固定されたセッション。
  - 行メニュー: 現在のアカウントにする、有効にする、優先度、削除。
- **次のリクエストの行き先と、その理由。**
  - 前のアカウントの理由、より高い優先度、または「ted のまま」。
- **全アカウントの合計とリセットのタイムライン。**
  - そのウィンドウをまだ使えるアカウントだけを数える、ティア別加重の集計。
  - 今後のすべてのウィンドウリセット。アカウントをローテーションに戻すものには `↑` が付きます。
- **実際のケースに対応するローテーション。**
  - 閉じたウィンドウを名指しする 429 は、その retry-after のあいだアカウントを制限します。
  - 単なる 429 は短時間だけ退避します。
  - 期限切れトークンは 1 回だけ更新して再試行します。
  - 403 と 5xx はフェイルオーバーします。
  - 全アカウントが枯渇したときは、失敗する代わりに設定した時間だけリクエストを保留できます。
- **セッション。**
  - 各 Claude Code セッションは週次バケットごとに同じアカウントにとどまります。
  - オプションの均等分配で、新しいセッションを最も空いているアカウントに割り当てます。
- **どこからでも切り替え。**
  - ポップオーバーのアカウントメニュー、右クリックメニュー、または `⌃⌥⌘N` で次の応答できるアカウントへ。
  - `⌃⌥⌘T` でポップオーバーを開きます。
- **意味のある通知。**
  - 全アカウントのしきい値、理由付きのローテーション、アカウントのローテーション離脱と復帰。
  - 再ログインの必要、プローブの失敗、ホールド、超過利用の課金。
  - 1 時間停止できます。
- **7 日分の履歴。**
  - アプリ実行中は毎分 1 サンプル: 全アカウントのスパークラインとアカウントごとの状態ストリップをローカルに保持します。
- **あなたの言語で。**
  - English、한국어、日本語、简体中文、Español、Deutsch、Français。
  - Mac の言語リストに従い、その場で切り替えられます。

## ギャラリー

#### アカウント
<img src="docs/assets/menubar/settings-accounts.png" width="780" alt="アカウントペイン">

#### ローテーション
<img src="docs/assets/menubar/settings-rotation.png" width="780" alt="ローテーションペイン: 切り替えしきい値、バケット別しきい値、セッション分配、枯渇時のホールド">

#### プロキシ
<img src="docs/assets/menubar/settings-proxy.png" width="780" alt="プロキシペイン: 待ち受けの状態と Claude Code に必要な 1 行">

#### 一般
<img src="docs/assets/menubar/settings-general.png" width="780" alt="一般ペイン: メニューバーのスタイル、言語、更新、ショートカット、通知">

## メニューバー項目

| 表示 | 意味 |
| --- | --- |
| `1h12m 42%` | 全アカウントの 5 時間ウィンドウが 1h12m 後にリセットされ、42% 使用済み。下のバーは 5 時間（上）と週次（下）。 |
| `ted 1h12m 42%` | 現在のアカウントに固定（設定 → 一般）: 3 文字のタグが先頭に付きます。 |
| `1h12m 42% · 3d12h 61%` | *バー + 5h · 7d* スタイル: 週次ウィンドウも表示します。 |
| `1h12m 93%!` | 重大: 切り替えしきい値に到達、または応答できるアカウントなし。 |
| `→ par` | ローテーションが起きた直後。6 秒間表示されます。 |
| `—` | 待ち受けが停止中（通常はポートが使用中）。 |
| `0%` | アカウント未登録。 |

## ショートカット

| キー | 場所 | 動作 |
| --- | --- | --- |
| `⌃⌥⌘N` | どこでも | 次の利用可能なアカウントに切り替え |
| `⌃⌥⌘T` | どこでも | ポップオーバーの表示/非表示 |
| `⌘R` `⌘T` `⌘,` `⌘Q` | ポップオーバー | 更新 · ターミナルで Claude Code を開く · 設定 · 終了 |
| 項目を右クリック | メニューバー | 切り替え、更新、設定を再読み込み、通知を停止 |

## 仕組み

- アプリは `127.0.0.1` で HTTP/1.1 リスナー（SwiftNIO）を動かします。
- 自身のコントロールプレーン以外のパスへのリクエストは、クライアントの `Authorization` を選ばれたアカウントのものに置き換えて `https://api.anthropic.com` へ転送します。
- ほかのヘッダーはすべてそのまま通過し、`metadata.user_id` にはトークンを送出したアカウントが入ります。
- 応答は届き次第ストリームで返されます。
- アカウントは優先度、次に最も早くリセットされる週次ウィンドウの順に選ばれます。
- 無効、制限中、上限到達、エラー状態、またはリクエストのモデルファミリーでしきい値に達しているアカウントはスキップされます。
- すべての応答に付く `anthropic-ratelimit-*` ヘッダーで各アカウントのウィンドウを最新に保ちます。
- usage エンドポイントのバックグラウンドプローブがアイドルなアカウントを埋めます。
- トークンは期限切れの 5 分前に更新されます。
- 設定は `~/Library/Application Support/Claude AutoSwitch/config.json` にあり、`0600` 権限でアトミックに書き込まれます。
- トークンはこのファイルにだけ保存されます。

設定ファイル、ヘルスエンドポイント、ローテーションルールのリファレンスは [docs/reference.md](docs/reference.md) にあります。

## プライバシー

接続先は 2 つのホストだけです: Claude API（リクエスト、usage プローブ、トークン更新）と、サインイン時の claude.ai / platform.claude.com。<br>
テレメトリもアップデート確認もありません。<br>
診断情報の書き出しは、書き込む前にすべてのシークレットを置き換えます。

## 利用規約について

複数の個人サブスクリプションにまたがってリクエストをローテーションすることは、Anthropic のコンシューマー向け規約が意図する範囲の外にあるかもしれません。<br>
このプロジェクトはあなた自身のアカウントのクォータを表示し、その使い方はあなたに委ねます。<br>
ご自身のプランに適用される規約をお読みください。

## ドキュメント

- [docs/troubleshooting.md](docs/troubleshooting.md): Gatekeeper、使用中のポート、再ログイン、ほかのツールと共有するトークン。
- [docs/reference.md](docs/reference.md): 設定ファイル、ヘルスエンドポイント、ローテーションルール。
- [CHANGELOG.md](CHANGELOG.md): 各リリースでの変更点。

## 開発

```sh
swift build
swift test            # engine tests run against loopback stand-ins for the Claude API
make app              # dist/Claude AutoSwitch.app
AUTOSWITCH_DEBUG_DEMO_QUOTA=1 CLAUDE_AUTOSWITCH_CONFIG=/tmp/demo.json swift run ClaudeAutoSwitch
```

- `AutoSwitchCore`: モデル（アカウント、ウィンドウ、ブロッカー）、ルール（スケジューリング、ペース、全アカウントの合計）、ローカライズ、設定ドキュメント。
- `AutoSwitchEngine`: プロキシ（アカウント、OAuth、クォータ、ローテーション、リスナー）。
- `ClaudeAutoSwitch`: アプリ。
- 文字列は `Sources/AutoSwitchCore/Resources/<lang>.lproj/Localizable.strings` に、英語のテキストをキーとして置かれています。
- ソース内の文字列に対応する行がそこになければ、テストが失敗します。
- `AUTOSWITCH_DEBUG_WINDOW=<section>` と `AUTOSWITCH_DEBUG_APPEARANCE=light|dark` で、スクリーンショット用に設定ペインとポップオーバーを開けます。
- `README.md` とその隣にある 6 つの翻訳は一緒に変更するもので、構造がずれると `scripts/check-readmes.sh` が失敗します。

## ライセンス

MIT.

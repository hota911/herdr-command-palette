# herdr-command-palette (hota911.command-palette)

English: [README.md](README.md)

herdr の組み込み操作（Workspace / Tab / Pane / Agent / Config）を fzf で呼び出すコマンドパレット。

![コマンドパレットのデモ](docs/assets/demo.gif)

## 使い方

`prefix+shift+p` を押す。現在の pane の上にパレットが popup として開き、下記のコマンドがすべて並
ぶ。操作を fuzzy search または矢印キーで選び、enter を押す。

- コマンドによっては実行前に追加の入力を求められる。
  - **自由入力**（タブのリネーム、workspace のディレクトリなど）— 値を入力して enter を押す。
    必須項目を空のまま確定するとキャンセル扱いになる。esc はいつでもキャンセルできる。
  - **一覧からの選択**（切り替え先の workspace、tab、agent など）— メインパレットと同様に fuzzy
    search または矢印キーで一覧から選ぶ。esc でキャンセル。
  - **確認**— 破壊的な操作（workspace / tab / pane を閉じる）は Yes/No で確認を求める。既定は No
    である。No を選ぶ、esc を押す、何も選ばず enter を押す、のいずれでも実行されない。
- メインの picker で esc を押すと、何もせずパレットを閉じる。

## 利用できるコマンド

- **Workspace:** 切り替え、次へ、前へ、新規作成、現在の workspace をリネーム、現在の workspace を閉じる
- **Tab:** 切り替え、次へ、前へ、新規作成、現在のタブをリネーム、現在のタブを閉じる
- **Pane:** 現在の pane をリネーム、現在の pane を閉じる、ズームの切り替え、左右上下へのフォーカ
  ス移動、右/下への分割、左右上下への入れ替え、左右上下へのリサイズ
- **Agent:** フォーカス
- **Config:** 設定の再読み込み

すべてのコマンドは、パレットを開いた pane / tab / workspace に対して作用する。ただし、設計上別
の対象を扱うコマンド（`Workspace: Switch…`、`Agent: Focus…` など）はこの限りではない。

### 対象外

このパレットは herdr の公開 CLI で実現できる範囲を対象にする。対応する操作がない built-in
keybinding とその理由は、設計文書の
[built-in keybinding 対応表](docs/design/command-catalog.md#mapping-to-built-in-keybindings)を参照。

## 要件

このプラグインはシステムツールを自動でインストールしない。以下は利用者が事前に用意する。

- [fzf](https://github.com/junegunn/fzf)
- [jq](https://github.com/jqlang/jq)
- herdr 0.8.0 以降

## インストール

```bash
herdr plugin install hota911/herdr-command-palette
```

ローカルで開発する場合は、作業コピーをリンクする。

```bash
herdr plugin link /path/to/herdr-command-palette
```

## キーバインド

`~/.config/herdr/config.toml` に以下を追加する。このプラグインの例は `prefix+shift+p` を使うため、
jt.command-palette を使う場合でも `prefix+p` は空けておける。

```toml
[[keys.command]]
key = "prefix+shift+p"
type = "plugin_action"
command = "hota911.command-palette.open"
description = "Command palette (built-ins)"
```

## 仕組み

- action `open` は herdr サーバー側（TTY なし）で走り、パレット本体を TTY を持つ popup pane とし
  て開く。popup は session-modal であり、tiled layout とは独立したサイズで表示され、pane 一覧には
  現れない。
- 利用中の herdr がこのプラグインの最低バージョンを満たさない場合、herdr はプラグイン自体をロー
  ドしない。herdr がこのカタログの前提とする protocol バージョンからずれている場合、あるいは
  protocol がまったく読み取れない場合は、パレットのヘッダーに警告が出る（動作自体は止まらず、カ
  タログが古い可能性があることを示すだけ）。選んだ操作が失敗した場合は、パレットが黙って閉じるこ
  とはなく、実行した group と subcommand、herdr 自身の出力を表示してキー入力を待つ。

## 関連プラグイン

JanTvrdík の [jt.command-palette](https://github.com/JanTvrdik/herdr-command-palette) はプラグイ
ン action の一覧を出すパレットであり、herdr 本体の組み込み操作（tab close、pane split など）は
対象に含まない。両者は役割が重ならないため並行して使える。`prefix+p` で jt.command-palette、
`prefix+shift+p` でこちらを開く。

このプラグインの popup 配管と実行エラーの可視化パターンは jt.command-palette（MIT）を踏襲して
おり、出典は [LICENSE](LICENSE) とソースコード内のコメントに記載する。

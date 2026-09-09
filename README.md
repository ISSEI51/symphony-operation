# symphony-operation

Symphonyを自分のリポジトリで運用するための手順書とセットアップスキル。

## Symphonyとは

GitHub Issueを起点にClaude Codeを常駐実行させるオーケストレータ。
本体は [sociotechnica-org/symphony-ts](https://github.com/sociotechnica-org/symphony-ts)。

Issueに `symphony:ready` ラベルを付けるだけで、あとは自動で進む。

```
Issue作成 + ラベル
   ↓  Symphonyが30秒以内に検知
隔離workspaceにclone
   ↓  Claude Codeが実装
Pull Request作成
   ↓  人間がレビュー
マージ
   ↓
Issue close + workspace削除
```

### 何が嬉しいか

**手を離せる**
ターミナルに張り付いてClaude Codeと対話する必要がない。Issueを積んでおけば、順番に実装されてPRが上がってくる。レビューだけすればよい。

**並列で回せる**
`max_concurrent_runs` を上げると複数Issueを同時に実装させられる。workspaceはIssueごとに隔離されるため、実装が互いに干渉しない。

**手元のcloneが汚れない**
作業はすべて別ディレクトリのcloneで行われる。自分が開いているエディタのブランチが勝手に切り替わることはない。

**中断しても壊れない**
実行状態はディスクに永続化される。マシンを再起動しても、実行中だったIssueの状態（PR作成済み、マージ待ちなど）を引き継いで再開する。同じIssueが二重に実装されることはない。

**マージにガードが効く**
PRができてもSymphonyは自動でマージしない。`/land` コメントを受け取った時点で、CIの成否・レビュースレッドの解決状況・mergeable判定を検証し、1つでも問題があればマージを拒否する。

**失敗が追える**
Issueごとに実行レポート（タイムライン、消費トークン、PR、失敗理由）が残る。失敗した場合はworkspaceも保持されるので、そのまま中に入って調査できる。

**対象repoを汚さない**
Symphonyの設定ファイルは対象リポジトリに一切置かない。すべて `~/symphony/<instance>/` に隔離される。既存のリポジトリにそのまま導入できる。

### 向いているもの / 向いていないもの

| 向いている | 向いていない |
| --- | --- |
| 仕様が文章で書けるIssue | 対話しながら方針を決めたいタスク |
| 独立した小〜中規模の変更 | 複数repoにまたがる変更 |
| 定型的な追加・修正・移植 | 探索的なリファクタリング |
| テストで正しさを判定できるもの | 判断基準が人の感覚に依存するもの |

## セットアップスキル

`skills/symphony-setup/` は、**対象プロジェクトのディレクトリでClaude Codeを起動して呼び出すだけ**でSymphonyを使える状態にするスキル。

やること:

1. git remote / `gh` 認証 / symphony-ts の存在を確認
2. `symphony init` でインスタンスを生成
3. 標準設定を適用（モデルをOpusに、AWS資格情報を遮断、auto-closingキーワード禁止ルールを追加）
4. Webアプリなら `bin/preview.sh` を設置
5. 起動コマンドとIssueの渡し方を提示

標準設定の中身は `SYMPHONY_USAGE.md` の第14章にすべて記載してある。スキルは同じ内容を自動で適用する。

### インストール

グローバルのスキルディレクトリにシンボリックリンクを張る。

```bash
just install
```

または手動で:

```bash
mkdir -p ~/.claude/skills
ln -sfn ~/dev/symphony-operation/skills/symphony-setup ~/.claude/skills/symphony-setup
```

### 使い方

対象リポジトリのルートでClaude Codeを起動し、こう頼む。

```
このリポジトリでSymphonyを使えるようにして
```

または直接呼び出す。

```
/symphony-setup
```

スクリプトだけを単体で実行することもできる。

```bash
cd <対象リポジトリ>
~/dev/symphony-operation/skills/symphony-setup/scripts/setup.sh
```

主なオプション:

| オプション | 既定 | 意味 |
| --- | --- | --- |
| `--repo <owner/repo>` | cwdのorigin | 対象リポジトリ |
| `--instance <name>` | リポジトリ名 | `~/symphony/` 配下のディレクトリ名 |
| `--model <alias>` | `opus` | Claude Codeのモデル |
| `--concurrency <n>` | 雛形の値 | 同時実行Issue数 |
| `--preview <yes\|no>` | 自動判定 | `bin/preview.sh` を設置するか |
| `--force` | — | 既存インスタンスを上書き |

## 前提

| 項目 | 内容 |
| --- | --- |
| symphony-ts | `~/tools/symphony-ts` にclone済み（`SYMPHONY_TS` で変更可） |
| gh | インストール済み、対象repoに対して認証済み |
| Claude Code | `claude -p` が非対話で実行できること |
| pnpm | symphony-tsの依存が入っていること |

## ファイル

```text
symphony-operation/
├── README.md
├── SYMPHONY_USAGE.md                     運用ガイド全文
├── images/                               TUIダッシュボードのスクリーンショット
├── justfile
└── skills/symphony-setup/
    ├── SKILL.md                          スキル定義
    └── scripts/
        ├── setup.sh                      インスタンス生成 + 標準設定適用
        └── preview.sh                    Issueごとにアプリを起動
```

## ドキュメント

- [`SYMPHONY_USAGE.md`](SYMPHONY_USAGE.md) — 運用ガイド。起動からマージ、複数repo運用、Webアプリの並列開発、標準設定の全文まで
- [symphony-ts](https://github.com/sociotechnica-org/symphony-ts) — Symphony本体

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

#### 1. 「プロンプトを書く → 待つ → 確認する」の繰り返しから解放される

通常のClaude Code運用では、1タスクごとに次のサイクルを人間が同期的に回すことになる。

```
プロンプトを書く → 実装が終わるまで待つ → 出力を確認する → 次のプロンプトを書く → ...
```

待っている間はターミナルの前から動けず、他の作業に頭を切り替えると戻ってきたときに文脈を失う。タスクが10個あれば、このサイクルを10回繰り返す。1回あたりの待ち時間が数分でも、切り替えのコストを含めると1日がこれで埋まる。

Symphonyでは、**やることを先にIssueとして積んでおく**。あとはSymphonyが順番に（`max_concurrent_runs` を上げれば並列で）実装し、PRになって上がってくる。

```
Issueをまとめて書く  →  （席を立つ）  →  PRがまとめて上がっている  →  レビューする
```

人間が関与するのはIssueを書く時点とPRを見る時点だけで、その間の待機が消える。1つずつプロンプトを書き直す必要も、実装中の画面を眺めている必要もない。

#### 2. 無駄な時間が減り、重要な判断に集中できる

Symphonyが引き受けるのは、**判断を必要としない機械的な作業**。

- workspaceの用意、ブランチ作成、cloneの管理
- エージェントの起動・監視・タイムアウト処理
- 実装完了の検知とPull Requestの作成
- CIの完了待ちとレビューコメントの追従
- マージ後のIssue close、ラベル整理、workspace削除
- 失敗時のリトライと状態の復旧

人間に残るのは、**判断が要る作業だけ**。

| 判断 | やること |
| --- | --- |
| 何を作るか | Issueを書く |
| 実装は正しいか | PRの差分を見る |
| マージしてよいか | `/land` する |

「ブランチを切る」「PRを作る」「Issueを閉じる」といった、考えなくても答えが決まっている操作に時間を使わなくなる。その分をIssueの設計とレビューに回せる。

#### これを支えている仕組み

| 性質 | 内容 |
| --- | --- |
| 並列実行 | workspaceはIssueごとに隔離されるため、複数の実装が互いに干渉しない |
| 手元のcloneが汚れない | 作業は別ディレクトリのcloneで行われる。開いているエディタのブランチが勝手に切り替わらない |
| 中断に強い | 実行状態はディスクに永続化される。再起動しても実行中だったIssueの状態を引き継ぎ、二重実装は起きない |
| マージのガード | `/land` を受け取ってから、CIの成否・レビュースレッド・mergeable判定を検証し、問題があれば拒否する |
| 失敗の追跡 | Issueごとに実行レポート（タイムライン、消費トークン、PR、失敗理由）が残る。失敗時はworkspaceも保持されるので中に入って調査できる |
| 導入が非破壊 | Symphonyの設定は対象リポジトリに一切置かない。既存repoにそのまま導入できる |

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

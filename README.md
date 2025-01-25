# github-personal-statistics

個人のGitHub活動量を計測し、Slackに通知するツール。月次の目標に対する進捗を日次で追跡します。

## 機能概要



### 計測指標

- コードの変更量（追加・削除行数）
- PRの作成数
- PRのマージ数

### 目標管理

- 月次で目標を設定
  - GitHub Actionsの変数で目標値を管理
  - 各指標に対して月間目標値を設定可能

- 日次で進捗を計算
  - 月間目標に対する達成率を計算
  - 日々の活動量を集計



### 通知機能

- GitHubアクティビティに基づくSlack通知
  - 個人のリポジトリ活動（コミット、PR作成、マージ）を検知して通知
  - 複数組織に所属している場合も個人の活動のみを対象
  - その日の活動量
  - 月間目標に対する現在の達成率
  - 残り日数に対する進捗状況



## 技術仕様

### 実装方針

- GitHub Actionsを主体とした実装
  - リポジトリ活動の検知による自動実行
  - 環境変数による目標値の管理

- GitHub CLI/APIの活用
  - 活動量データの取得
  - 認証情報は適切に管理

- シンプルな実装
  - 個人利用を前提とした最小限の機能
  - メンテナンス性を考慮

### セキュリティ

- 秘匿情報（Slack Webhook URL等）はGitHub Secretsで管理
- ソースコード上に機密情報を含まない

## 実装詳細

### GitHub Actions Workflow

```yaml

name: GitHub Activity Report
on:
  # 個人のリポジトリ活動を検知
  push:
    branches: [ main, master ]
  pull_request:
    types: [ opened, closed ]
  workflow_dispatch:      # 手動実行用

env:
  MONTHLY_CODE_CHANGES_GOAL: ${{ vars.MONTHLY_CODE_CHANGES_GOAL }}
  MONTHLY_PR_CREATION_GOAL: ${{ vars.MONTHLY_PR_CREATION_GOAL }}
  MONTHLY_PR_MERGE_GOAL: ${{ vars.MONTHLY_PR_MERGE_GOAL }}
  USERNAME: ${{ vars.USERNAME }}

jobs:
  report:
    # 個人の活動のみを対象とする
    if: github.actor == vars.USERNAME
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Generate Activity Report
        run: |
          chmod +x ./scripts/generate_report.sh
          ./scripts/generate_report.sh
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
```

### シェルスクリプト (scripts/generate_report.sh)

活動量の取得と計算を行うシェルスクリプト:



1) コード変更量の取得

```bash
# GraphQL APIを使用して過去24時間のコミット統計を取得
gh api graphql -f query='
  query($owner: String!, $from: DateTime!) {
    user(login: $owner) {
      contributionsCollection(from: $from) {
        totalCommitContributions
        totalLinesChanged
      }
    }
  }
'
```

2) PR統計の取得

```bash
# 作成したPR数
gh pr list --author @me --state all --json createdAt | \
  jq '[.[] | select(.createdAt >= (now - 86400 | todate))] | length'

# マージされたPR数
gh pr list --author @me --state merged --json mergedAt | \
  jq '[.[] | select(.mergedAt >= (now - 86400 | todate))] | length'
```

3) 進捗率の計算

- 月初からの累計値を計算
- 月間目標に対する達成率を計算
- 残り日数に対する必要な1日あたりの達成数を計算

4) Slack通知フォーマット

```json
{
  "blocks": [
    {
      "type": "header",
      "text": {
        "type": "plain_text",
        "text": "📊 GitHub Activity Report"
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*Today's Activity*\n• Code Changes: {changes} lines\n• PRs Created: {created}\n• PRs Merged: {merged}"
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*Monthly Progress*\n• Code Changes: {total_changes}/{goal_changes} ({progress}%)\n• PRs Created: {total_created}/{goal_created} ({progress}%)\n• PRs Merged: {total_merged}/{goal_merged} ({progress}%)"
      }
    }
  ]
}
```

### 設定項目

1. GitHub Actions Variables

- `MONTHLY_CODE_CHANGES_GOAL`: 月間のコード変更行数目標 (正の整数)
- `MONTHLY_PR_CREATION_GOAL`: 月間のPR作成数目標 (正の整数)
- `MONTHLY_PR_MERGE_GOAL`: 月間のPRマージ数目標 (正の整数)
- `USERNAME`: 個人のGitHubユーザー名（活動フィルタリング用）
- `DEBUG`: デバッグモードの有効化 (オプション、デフォルト: false)

2. GitHub Secrets

- `GITHUB_TOKEN`: GitHub APIアクセス用（自動設定）
- `SLACK_WEBHOOK_URL`: Slack通知用Webhook URL

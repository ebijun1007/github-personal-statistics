#!/bin/bash

set -e

# 環境変数の確認
for var in "GITHUB_TOKEN" "SLACK_WEBHOOK_URL" "USERNAME"; do
    if [ -z "${!var}" ]; then
        echo "Error: $var is not set"
        exit 1
    fi
done

# 月間目標値の確認
for goal in "MONTHLY_CODE_CHANGES_GOAL" "MONTHLY_PR_CREATION_GOAL" "MONTHLY_PR_MERGE_GOAL"; do
    if [ -z "${!goal}" ]; then
        echo "Error: $goal is not set"
        exit 1
    fi
    if ! [[ "${!goal}" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: $goal must be a positive integer"
        exit 1
    fi
done

# 過去24時間の期間を設定
FROM_DATE=$(date -d '24 hours ago' -u +"%Y-%m-%dT%H:%M:%SZ")
CURRENT_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# 月初めの日付を設定
MONTH_START=$(date -d "$(date +%Y-%m-01)" -u +"%Y-%m-%dT%H:%M:%SZ")

# コミット統計の取得
echo "Fetching commit statistics..."
STATS=$(gh api graphql -f query='
  query($owner: String!, $dailyFrom: DateTime!, $monthStart: DateTime!) {
    daily: user(login: $owner) {
      contributionsCollection(from: $dailyFrom) {
        totalCommitContributions
        commitContributionsByRepository {
          repository {
            name
          }
          contributions {
            totalCount
          }
        }
      }
    }
    monthly: user(login: $owner) {
      contributionsCollection(from: $monthStart) {
        totalCommitContributions
        commitContributionsByRepository {
          repository {
            name
          }
          contributions {
            totalCount
          }
        }
      }
    }
  }
' -f owner="$USERNAME" -f dailyFrom="$FROM_DATE" -f monthStart="$MONTH_START")

# APIレスポンスの検証
if ! echo "$STATS" | jq -e '.data.daily.contributionsCollection' >/dev/null; then
    echo "Error: Invalid daily stats response"
    [ "${DEBUG:-false}" = "true" ] && echo "Debug: Response: $STATS"
    exit 1
fi

if ! echo "$STATS" | jq -e '.data.monthly.contributionsCollection' >/dev/null; then
    echo "Error: Invalid monthly stats response"
    [ "${DEBUG:-false}" = "true" ] && echo "Debug: Response: $STATS"
    exit 1
fi

# 統計データの抽出
DAILY_COMMITS=$(echo "$STATS" | jq '.data.daily.contributionsCollection.totalCommitContributions')
MONTHLY_COMMITS=$(echo "$STATS" | jq '.data.monthly.contributionsCollection.totalCommitContributions')

# コミット数を変更行数の近似値として使用 (1コミットあたり平均20行の変更と仮定)
DAILY_CHANGES=$((DAILY_COMMITS * 20))
MONTHLY_CHANGES=$((MONTHLY_COMMITS * 20))

# PR統計の取得
echo "Fetching PR statistics..."

# 24時間以内のPR作成数
DAILY_PRS_CREATED=$(gh pr list --author "@me" --state all --json createdAt | \
  jq --arg from "$FROM_DATE" '[.[] | select(.createdAt >= $from)] | length')

# 24時間以内のPRマージ数
DAILY_PRS_MERGED=$(gh pr list --author "@me" --state merged --json mergedAt | \
  jq --arg from "$FROM_DATE" '[.[] | select(.mergedAt >= $from)] | length')

# 月初めからのPR作成数
MONTHLY_PRS_CREATED=$(gh pr list --author "@me" --state all --json createdAt | \
  jq --arg from "$MONTH_START" '[.[] | select(.createdAt >= $from)] | length')

# 月初めからのPRマージ数
MONTHLY_PRS_MERGED=$(gh pr list --author "@me" --state merged --json mergedAt | \
  jq --arg from "$MONTH_START" '[.[] | select(.mergedAt >= $from)] | length')

# bcコマンドの確認
if ! command -v bc &> /dev/null; then
    echo "Error: bc command not found"
    exit 1
fi

# 進捗率計算用の関数
calculate_progress() {
    local current=$1
    local goal=$2
    if [ "$goal" -eq 0 ]; then
        echo "Error: monthly goal cannot be zero"
        exit 1
    fi
    echo "scale=2; $current * 100 / $goal" | bc
}

# 月間目標に対する進捗率の計算
CHANGES_PROGRESS=$(calculate_progress "$MONTHLY_CHANGES" "$MONTHLY_CODE_CHANGES_GOAL")
PR_CREATION_PROGRESS=$(calculate_progress "$MONTHLY_PRS_CREATED" "$MONTHLY_PR_CREATION_GOAL")
PR_MERGE_PROGRESS=$(calculate_progress "$MONTHLY_PRS_MERGED" "$MONTHLY_PR_MERGE_GOAL")

# 残り日数の計算
DAYS_IN_MONTH=$(date -d "$(date +%Y-%m-01) +1 month -1 day" +%d)
CURRENT_DAY=$(date +%d)
REMAINING_DAYS=$((DAYS_IN_MONTH - CURRENT_DAY + 1))

# Slack通知用のJSONペイロードを作成
PAYLOAD=$(cat <<EOF
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
        "text": "*Today's Activity*\n• Commits: ${DAILY_COMMITS} (≈${DAILY_CHANGES} lines)\n• PRs Created: ${DAILY_PRS_CREATED}\n• PRs Merged: ${DAILY_PRS_MERGED}"
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*Monthly Progress*\n• Commits: ${MONTHLY_COMMITS} (≈${MONTHLY_CHANGES}/${MONTHLY_CODE_CHANGES_GOAL} lines, ${CHANGES_PROGRESS}%)\n• PRs Created: ${MONTHLY_PRS_CREATED}/${MONTHLY_PR_CREATION_GOAL} (${PR_CREATION_PROGRESS}%)\n• PRs Merged: ${MONTHLY_PRS_MERGED}/${MONTHLY_PR_MERGE_GOAL} (${PR_MERGE_PROGRESS}%)"
      }
    },
    {
      "type": "section",
      "text": {
        "type": "mrkdwn",
        "text": "*Remaining Days in Month: ${REMAINING_DAYS}*"
      }
    }
  ]
}
EOF
)

# Slackに通知を送信
echo "Sending notification to Slack..."

if [ "${DEBUG:-false}" = "true" ]; then
    echo "Debug: Slack payload"
    echo "$PAYLOAD" | jq '.'
fi

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    -H 'Content-type: application/json' \
    --data "$PAYLOAD" "$SLACK_WEBHOOK_URL")
HTTP_STATUS=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_STATUS" -ne 200 ]; then
    echo "Error: Failed to send Slack notification (HTTP $HTTP_STATUS)"
    [ "${DEBUG:-false}" = "true" ] && echo "Debug: Response body: $RESPONSE_BODY"
    exit 1
fi

[ "${DEBUG:-false}" = "true" ] && echo "Debug: Successfully sent notification to Slack"

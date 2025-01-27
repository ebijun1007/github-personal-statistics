#!/bin/bash

set -e

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" 1>&2
}

log "Starting GitHub Activity Report script"

# 環境変数の確認
for var in "GITHUB_TOKEN" "SLACK_WEBHOOK_URL" "USERNAME"; do
    if [ -z "${!var}" ]; then
        log "Error: $var is not set"
        exit 1
    fi
    log "Confirmed $var is set"
done

# リポジトリ情報の設定
REPO_OWNER="${REPO_OWNER:-$USERNAME}"

# リポジトリ所有者の確認
if [ -z "$REPO_OWNER" ]; then
    log "Error: REPO_OWNER is not set"
    exit 1
fi
log "Confirmed REPO_OWNER is set"

# 所有リポジトリの一覧を取得
log "Fetching repository list for $REPO_OWNER..."
REPOS=$(gh repo list "$REPO_OWNER" --json name --jq '.[].name' --limit 100)
if [ -z "$REPOS" ]; then
    log "Warning: No repositories found for $REPO_OWNER"
fi
log "Found repositories for $REPO_OWNER"

# 月間目標値の確認
for goal in "MONTHLY_CODE_CHANGES_GOAL" "MONTHLY_PR_CREATION_GOAL" "MONTHLY_PR_MERGE_GOAL"; do
    if [ -z "${!goal}" ]; then
        log "Error: $goal is not set"
        exit 1
    fi
    if ! [[ "${!goal}" =~ ^[1-9][0-9]*$ ]]; then
        log "Error: $goal must be a positive integer"
        exit 1
    fi
    log "$goal is set to ${!goal}"
done

# 過去24時間の期間を設定
FROM_DATE=$(date -d '24 hours ago' -u +"%Y-%m-%dT%H:%M:%SZ")
CURRENT_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
MONTH_START=$(date -d "$(date +%Y-%m-01)" -u +"%Y-%m-%dT%H:%M:%SZ")

log "Time ranges:"
log "- From: $FROM_DATE"
log "- Current: $CURRENT_DATE"
log "- Month Start: $MONTH_START"

# コミット統計の取得
log "Fetching commit statistics..."

# 個人の活動量を取得
log "Fetching personal commit statistics..."
PERSONAL_STATS=$(gh api graphql -f query='
  query($owner: String!, $dailyFrom: DateTime!, $monthStart: DateTime!) {
    daily: user(login: $owner) {
      contributionsCollection(from: $dailyFrom) {
        totalCommitContributions
        commitContributionsByRepository {
          repository {
            nameWithOwner
            defaultBranchRef {
              target {
                ... on Commit {
                  history(first: 100, author: {emails: ["*"]}) {
                    nodes {
                      additions
                      deletions
                      committedDate
                      author {
                        email
                        user {
                          login
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    monthly: user(login: $owner) {
      contributionsCollection(from: $monthStart) {
        totalCommitContributions
        commitContributionsByRepository {
          repository {
            nameWithOwner
            defaultBranchRef {
              target {
                ... on Commit {
                  history(first: 100, author: {emails: ["*"]}) {
                    nodes {
                      additions
                      deletions
                      committedDate
                      author {
                        email
                        user {
                          login
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
' -f owner="$USERNAME" -f dailyFrom="$FROM_DATE" -f monthStart="$MONTH_START")

# リポジトリ全体の活動量を取得
log "Fetching repository-wide commit statistics..."
REPO_STATS=""
while IFS= read -r repo; do
    log "Fetching commits for repository: $repo"
    REPO_QUERY=$(gh api graphql -f query='
      query($owner: String!, $repo: String!, $dailyFrom: DateTime!, $monthStart: DateTime!) {
        daily: repository(owner: $owner, name: $repo) {
          defaultBranchRef {
            target {
              ... on Commit {
                history(first: 100, since: $dailyFrom) {
                  nodes {
                    additions
                    deletions
                    committedDate
                    author {
                      email
                      user {
                        login
                      }
                    }
                  }
                }
              }
            }
          }
        }
        monthly: repository(owner: $owner, name: $repo) {
          defaultBranchRef {
            target {
              ... on Commit {
                history(first: 100, since: $monthStart) {
                  nodes {
                    additions
                    deletions
                    committedDate
                    author {
                      email
                      user {
                        login
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    ' -f owner="$REPO_OWNER" -f repo="$repo" -f dailyFrom="$FROM_DATE" -f monthStart="$MONTH_START")
    
    if [ -z "$REPO_STATS" ]; then
        REPO_STATS="$REPO_QUERY"
    else
        REPO_STATS="$REPO_STATS\n$REPO_QUERY"
    fi
done <<< "$REPOS"

log "Raw GitHub API Response:"
echo "$STATS" | jq '.'

# 変更行数の計算関数
calculate_personal_changes() {
    local json=$1
    local period=$2
    local since=$3
    local username=$4

    log "Calculating personal changes:"
    log "- Period: $period"
    log "- Since: $since"
    log "- Username: $username"

    # jqの出力をraw-outputで整形し、空白をトリム
    local result=$(echo "$json" | jq --raw-output --arg since "$since" --arg period "$period" --arg username "$username" '
        [.data[$period].contributionsCollection.commitContributionsByRepository[] |
        select(.repository.defaultBranchRef != null) |
        .repository.defaultBranchRef.target.history.nodes[] |
        select(.committedDate >= $since and .author.user.login == $username) |
        (.additions + .deletions)] |
        add // 0
    ' | tr -d '[:space:]')

    log "Calculated personal changes for $period since $since: $result"
    echo "${result:-0}"
}

calculate_repo_changes() {
    local json=$1
    local period=$2
    local since=$3

    log "Calculating repository changes:"
    log "- Period: $period"
    log "- Since: $since"

    # 各リポジトリの変更を集計
    local result=0
    while IFS= read -r repo_stats; do
        if [ -n "$repo_stats" ]; then
            local repo_changes=$(echo "$repo_stats" | jq --raw-output --arg since "$since" --arg period "$period" '
                [.[$period].defaultBranchRef.target.history.nodes[] |
                select(.committedDate >= $since) |
                (.additions + .deletions)] |
                add // 0
            ' | tr -d '[:space:]')
            result=$((result + ${repo_changes:-0}))
        fi
    done <<< "$(echo -e "$json")"

    log "Calculated repository changes for $period since $since: $result"
    echo "$result"
}

# 重複を除いた合計を計算する関数
calculate_total_changes() {
    local personal_changes=$1
    local repo_changes=$2
    local overlap_changes=$3

    log "Calculating total changes:"
    log "- Personal changes: $personal_changes"
    log "- Repository changes: $repo_changes"
    log "- Overlap changes: $overlap_changes"

    # 重複を除いた合計を計算
    local total=$((personal_changes + repo_changes - overlap_changes))
    log "Total changes (without double counting): $total"
    echo "$total"
}

# 個人の変更行数の計算
log "Calculating personal changes..."
DAILY_PERSONAL_CHANGES=$(calculate_personal_changes "$PERSONAL_STATS" "daily" "$FROM_DATE" "$USERNAME")
MONTHLY_PERSONAL_CHANGES=$(calculate_personal_changes "$PERSONAL_STATS" "monthly" "$MONTH_START" "$USERNAME")

log "Personal changes:"
log "- Daily: $DAILY_PERSONAL_CHANGES"
log "- Monthly: $MONTHLY_PERSONAL_CHANGES"

# リポジトリ全体の変更行数の計算
log "Calculating repository changes..."
DAILY_REPO_CHANGES=$(calculate_repo_changes "$REPO_STATS" "daily" "$FROM_DATE")
MONTHLY_REPO_CHANGES=$(calculate_repo_changes "$REPO_STATS" "monthly" "$MONTH_START")

log "Repository changes:"
log "- Daily: $DAILY_REPO_CHANGES"
log "- Monthly: $MONTHLY_REPO_CHANGES"

# オーバーラップの計算（個人の変更のうち、自分のリポジトリでの変更分）
log "Calculating overlap changes..."
DAILY_OVERLAP_CHANGES=$(calculate_personal_changes "$PERSONAL_STATS" "daily" "$FROM_DATE" "$USERNAME")
MONTHLY_OVERLAP_CHANGES=$(calculate_personal_changes "$PERSONAL_STATS" "monthly" "$MONTH_START" "$USERNAME")

log "Overlap changes:"
log "- Daily: $DAILY_OVERLAP_CHANGES"
log "- Monthly: $MONTHLY_OVERLAP_CHANGES"

# 重複を除いた合計の計算
log "Calculating total changes (without double counting)..."
DAILY_CHANGES=$(calculate_total_changes "$DAILY_PERSONAL_CHANGES" "$DAILY_REPO_CHANGES" "$DAILY_OVERLAP_CHANGES")
MONTHLY_CHANGES=$(calculate_total_changes "$MONTHLY_PERSONAL_CHANGES" "$MONTHLY_REPO_CHANGES" "$MONTHLY_OVERLAP_CHANGES")

log "Final changes (without double counting):"
log "- Daily: $DAILY_CHANGES"
log "- Monthly: $MONTHLY_CHANGES"

# 数値の検証
if ! [[ "$DAILY_CHANGES" =~ ^[0-9]+$ ]]; then
    log "Error: Invalid daily changes value: $DAILY_CHANGES"
    exit 1
fi

if ! [[ "$MONTHLY_CHANGES" =~ ^[0-9]+$ ]]; then
    log "Error: Invalid monthly changes value: $MONTHLY_CHANGES"
    exit 1
fi

log "Change counts validated"

log "Fetching PR statistics..."

# PR統計の初期化
DAILY_PRS_CREATED=0
DAILY_PRS_MERGED=0
MONTHLY_PRS_CREATED=0
MONTHLY_PRS_MERGED=0

# 全リポジトリに対してPR情報を取得
while IFS= read -r repo; do
    log "Fetching PRs for repository: $repo"
    PR_QUERY=$(gh api graphql -f query='
      query($repoOwner: String!, $repoName: String!) {
        repository(owner: $repoOwner, name: $repoName) {
          pullRequests(first: 100, states: [OPEN, CLOSED, MERGED], orderBy: {field: CREATED_AT, direction: DESC}) {
            nodes {
              createdAt
              mergedAt
              state
              author {
                login
              }
            }
          }
        }
      }
    ' -f repoOwner="$REPO_OWNER" -f repoName="$repo")

    log "Processing PR data for $repo"
    
    # リポジトリごとのPR統計を計算
    REPO_DAILY_PRS_CREATED=$(echo "$PR_QUERY" | jq --arg from "$FROM_DATE" --arg username "$USERNAME" '[.data.repository.pullRequests.nodes[] | select(.createdAt >= $from and .author.login == $username)] | length')
    REPO_DAILY_PRS_MERGED=$(echo "$PR_QUERY" | jq --arg from "$FROM_DATE" --arg username "$USERNAME" '[.data.repository.pullRequests.nodes[] | select(.mergedAt != null and .mergedAt >= $from and .author.login == $username)] | length')
    REPO_MONTHLY_PRS_CREATED=$(echo "$PR_QUERY" | jq --arg from "$MONTH_START" --arg username "$USERNAME" '[.data.repository.pullRequests.nodes[] | select(.createdAt >= $from and .author.login == $username)] | length')
    REPO_MONTHLY_PRS_MERGED=$(echo "$PR_QUERY" | jq --arg from "$MONTH_START" --arg username "$USERNAME" '[.data.repository.pullRequests.nodes[] | select(.mergedAt != null and .mergedAt >= $from and .author.login == $username)] | length')

    # 合計に加算
    DAILY_PRS_CREATED=$((DAILY_PRS_CREATED + REPO_DAILY_PRS_CREATED))
    DAILY_PRS_MERGED=$((DAILY_PRS_MERGED + REPO_DAILY_PRS_MERGED))
    MONTHLY_PRS_CREATED=$((MONTHLY_PRS_CREATED + REPO_MONTHLY_PRS_CREATED))
    MONTHLY_PRS_MERGED=$((MONTHLY_PRS_MERGED + REPO_MONTHLY_PRS_MERGED))

    log "Repository $repo PR stats:"
    log "- Daily Created: $REPO_DAILY_PRS_CREATED"
    log "- Daily Merged: $REPO_DAILY_PRS_MERGED"
    log "- Monthly Created: $REPO_MONTHLY_PRS_CREATED"
    log "- Monthly Merged: $REPO_MONTHLY_PRS_MERGED"
done <<< "$REPOS"

log "Total PR Statistics:"
log "- Total Daily PRs Created: $DAILY_PRS_CREATED"
log "- Total Daily PRs Merged: $DAILY_PRS_MERGED"
log "- Total Monthly PRs Created: $MONTHLY_PRS_CREATED"
log "- Total Monthly PRs Merged: $MONTHLY_PRS_MERGED"

log "PR Statistics:"
log "- Daily PRs Created: $DAILY_PRS_CREATED"
log "- Daily PRs Merged: $DAILY_PRS_MERGED"
log "- Monthly PRs Created: $MONTHLY_PRS_CREATED"
log "- Monthly PRs Merged: $MONTHLY_PRS_MERGED"

# bcコマンドの確認
if ! command -v bc &> /dev/null; then
    log "Error: bc command not found"
    exit 1
fi
log "bc command available"

# 進捗率計算用の関数
calculate_progress() {
    local current=$1
    local goal=$2
    if [ "$goal" -eq 0 ]; then
        log "Error: monthly goal cannot be zero"
        exit 1
    fi
    local progress=$(printf "%.2f" "$(echo "scale=2; $current * 100 / $goal" | bc)")
    log "Progress calculation: $current / $goal = $progress%"
    echo "$progress"
}

# 月間目標に対する進捗率の計算
CHANGES_PROGRESS=$(calculate_progress "$MONTHLY_CHANGES" "$MONTHLY_CODE_CHANGES_GOAL")
PR_CREATION_PROGRESS=$(calculate_progress "$MONTHLY_PRS_CREATED" "$MONTHLY_PR_CREATION_GOAL")
PR_MERGE_PROGRESS=$(calculate_progress "$MONTHLY_PRS_MERGED" "$MONTHLY_PR_MERGE_GOAL")

# 残り日数の計算
DAYS_IN_MONTH=$(date -d "$(date +%Y-%m-01) +1 month -1 day" +%d)
CURRENT_DAY=$(date +%d)
REMAINING_DAYS=$((DAYS_IN_MONTH - CURRENT_DAY + 1))

log "Time calculations:"
log "- Days in month: $DAYS_IN_MONTH"
log "- Current day: $CURRENT_DAY"
log "- Remaining days: $REMAINING_DAYS"

# Slack通知用のJSONペイロードを作成
log "Creating Slack payload..."
PAYLOAD=$(jq -n \
  --arg daily_personal_changes "$DAILY_PERSONAL_CHANGES" \
  --arg daily_repo_changes "$DAILY_REPO_CHANGES" \
  --arg daily_changes "$DAILY_CHANGES" \
  --arg daily_prs_created "$DAILY_PRS_CREATED" \
  --arg daily_prs_merged "$DAILY_PRS_MERGED" \
  --arg monthly_personal_changes "$MONTHLY_PERSONAL_CHANGES" \
  --arg monthly_repo_changes "$MONTHLY_REPO_CHANGES" \
  --arg monthly_changes "$MONTHLY_CHANGES" \
  --arg monthly_goal "$MONTHLY_CODE_CHANGES_GOAL" \
  --arg changes_progress "$CHANGES_PROGRESS" \
  --arg monthly_prs_created "$MONTHLY_PRS_CREATED" \
  --arg pr_creation_goal "$MONTHLY_PR_CREATION_GOAL" \
  --arg pr_creation_progress "$PR_CREATION_PROGRESS" \
  --arg monthly_prs_merged "$MONTHLY_PRS_MERGED" \
  --arg pr_merge_goal "$MONTHLY_PR_MERGE_GOAL" \
  --arg pr_merge_progress "$PR_MERGE_PROGRESS" \
  --arg remaining_days "$REMAINING_DAYS" \
  '{
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
          "text": "*Activity Metrics Explanation*\n• Personal Changes: All commits by you across any repository\n• Repository Changes: All commits in your repositories\n• Total Changes: Combined activity without double-counting"
        }
      },
      {
        "type": "section",
        "text": {
          "type": "mrkdwn",
          "text": "*Today'\''s Activity*\n• Personal Changes: \($daily_personal_changes) lines\n• Repository Changes: \($daily_repo_changes) lines\n• Total Changes (No Double Count): \($daily_changes) lines\n• PRs Created: \($daily_prs_created)\n• PRs Merged: \($daily_prs_merged)"
        }
      },
      {
        "type": "section",
        "text": {
          "type": "mrkdwn",
          "text": "*Monthly Progress*\n• Personal Changes: \($monthly_personal_changes) lines\n• Repository Changes: \($monthly_repo_changes) lines\n• Total Changes (No Double Count): \($monthly_changes)/\($monthly_goal) lines (\($changes_progress)%)\n• PRs Created: \($monthly_prs_created)/\($pr_creation_goal) (\($pr_creation_progress)%)\n• PRs Merged: \($monthly_prs_merged)/\($pr_merge_goal) (\($pr_merge_progress)%)"
        }
      },
      {
        "type": "section",
        "text": {
          "type": "mrkdwn",
          "text": "*Remaining Days in Month: \($remaining_days)*"
        }
      }
    ]
  }')

log "Slack payload:"
echo "$PAYLOAD" | jq '.'

# Slackに通知を送信
log "Sending notification to Slack..."

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
    -H 'Content-type: application/json' \
    --data "$PAYLOAD" "$SLACK_WEBHOOK_URL")
HTTP_STATUS=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

log "Slack API Response:"
log "- Status Code: $HTTP_STATUS"
log "- Response Body: $RESPONSE_BODY"

if [ "$HTTP_STATUS" -ne 200 ]; then
    log "Error: Failed to send Slack notification (HTTP $HTTP_STATUS)"
    exit 1
fi

log "Successfully completed GitHub Activity Report"

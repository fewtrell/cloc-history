#!/usr/bin/env bash
#
# cloc-history.sh - Track lines of code across every commit in a git repo
#
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: cloc-history.sh [OPTIONS] [-- CLOC_OPTIONS...]

Track lines of code (via cloc) for every commit in a git repository's history.
Commits are shown in chronological order with deltas between each row.

Options:
  -h, --help              Show this help message
  -s, --summarize MODE    Group results: "commit" (default), "day", "week",
                          "month", or "year"
  -n, --max-commits N     Process only the last N commits
  --all-parents           Follow all parents at merges (default: first-parent only)

Everything after -- is passed directly to cloc. Use this to filter languages,
exclude directories, etc.

Examples:
  cloc-history.sh
  cloc-history.sh -s day
  cloc-history.sh -s week -n 200
  cloc-history.sh -- --exclude-dir=vendor,node_modules
  cloc-history.sh -- --include-lang=Python,JavaScript
  cloc-history.sh -s month
  cloc-history.sh -s year
  cloc-history.sh -s day -- --exclude-ext=json,yaml
USAGE
    exit 0
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
SUMMARIZE="commit"
MAX_COMMITS=""
FIRST_PARENT="--first-parent"
CLOC_OPTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)        usage ;;
        -s|--summarize)   SUMMARIZE="$2"; shift 2 ;;
        -n|--max-commits) MAX_COMMITS="$2"; shift 2 ;;
        --all-parents)    FIRST_PARENT=""; shift ;;
        --)               shift; CLOC_OPTS=("$@"); break ;;
        *)                echo "Error: unknown option: $1" >&2
                          echo "Use -h for help." >&2
                          exit 1 ;;
    esac
done

if [[ ! "$SUMMARIZE" =~ ^(commit|day|week|month|year)$ ]]; then
    echo "Error: --summarize must be 'commit', 'day', 'week', 'month', or 'year' (got '$SUMMARIZE')" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Validate environment
# ---------------------------------------------------------------------------
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "Error: not inside a git repository." >&2
    exit 1
fi

if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    echo "Error: repository has uncommitted changes. Commit or stash them first." >&2
    exit 1
fi

if ! command -v cloc &>/dev/null; then
    echo "Error: 'cloc' is not installed. Install it with: brew install cloc" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Gather commits (oldest first)
# ---------------------------------------------------------------------------
REPO_ROOT=$(git rev-parse --show-toplevel)

git_log_args=(log --format='%H' --reverse)
[[ -n "$FIRST_PARENT" ]] && git_log_args+=("$FIRST_PARENT")
[[ -n "$MAX_COMMITS" ]]  && git_log_args+=("-n" "$MAX_COMMITS")
git_log_args+=("HEAD")

commits=()
while IFS= read -r hash; do
    commits+=("$hash")
done < <(git "${git_log_args[@]}")

total=${#commits[@]}
if [[ $total -eq 0 ]]; then
    echo "No commits found." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# When summarizing by period, only the last commit per period needs cloc.
# Pre-scan commit dates (cheap) to decide which commits to skip.
# ---------------------------------------------------------------------------
declare -a run_cloc
for i in "${!commits[@]}"; do run_cloc[$i]=1; done

if [[ "$SUMMARIZE" != "commit" ]]; then
    case "$SUMMARIZE" in
        day)   pfmt='%Y-%m-%d' ;;
        week)  pfmt='%G-W%V'   ;;
        month) pfmt='%Y-%m'    ;;
        year)  pfmt='%Y'       ;;
    esac

    # Get the period key for every commit in one batch git-log call
    period_log_args=(log --format='%ad' --date=format:"$pfmt" --reverse)
    [[ -n "$FIRST_PARENT" ]] && period_log_args+=("$FIRST_PARENT")
    [[ -n "$MAX_COMMITS" ]]  && period_log_args+=("-n" "$MAX_COMMITS")
    period_log_args+=("HEAD")

    periods=()
    while IFS= read -r p; do
        periods+=("$p")
    done < <(git "${period_log_args[@]}")

    # Only keep the last commit in each period (skip earlier ones)
    for i in "${!commits[@]}"; do
        next=$((i + 1))
        if [[ $next -lt $total && "${periods[$i]}" == "${periods[$next]}" ]]; then
            run_cloc[$i]=0
        fi
    done
fi

to_process=0
for v in "${run_cloc[@]}"; do ((to_process += v)); done

echo "Processing $to_process of $total commits (grouped by $SUMMARIZE)..." >&2

# ---------------------------------------------------------------------------
# Temporary worktree (cleaned up on exit)
# ---------------------------------------------------------------------------
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cloc-history.XXXXXX")

cleanup() {
    git -C "$REPO_ROOT" worktree remove --force "$WORK_DIR" 2>/dev/null || true
    rm -rf "$WORK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

git -C "$REPO_ROOT" worktree add --quiet --detach "$WORK_DIR" HEAD

# ---------------------------------------------------------------------------
# Process each commit
# ---------------------------------------------------------------------------
prev_code=0
results=()
processed=0

for i in "${!commits[@]}"; do
    commit="${commits[$i]}"

    # Skip commits that aren't the last in their period
    if [[ "${run_cloc[$i]}" -eq 0 ]]; then
        printf '\r  [%d/%d] skipping %s' "$((i + 1))" "$total" \
            "$(git log -1 --format='%h' "$commit")" >&2
        continue
    fi

    ((processed += 1))
    git -C "$WORK_DIR" checkout --quiet --force "$commit" 2>/dev/null

    # Commit metadata
    short=$(git   log -1 --format='%h'  "$commit")
    day=$(git     log -1 --format='%ad' --date=format:'%Y-%m-%d' "$commit")
    week=$(git    log -1 --format='%ad' --date=format:'%G-W%V'   "$commit")
    month=$(git   log -1 --format='%ad' --date=format:'%Y-%m'    "$commit")
    year=$(git    log -1 --format='%ad' --date=format:'%Y'       "$commit")
    subject=$(git log -1 --format='%s'  "$commit")

    # Count code lines (only git-tracked files)
    code=$(
        cd "$WORK_DIR" \
        && cloc --vcs=git --csv ${CLOC_OPTS[@]+"${CLOC_OPTS[@]}"} 2>/dev/null \
        |  awk -F, '$2 == "SUM" { print $5 }'
    ) || true
    code=$(echo "$code" | tr -d '[:space:]')
    code=${code:-0}

    delta=$((code - prev_code))
    prev_code=$code

    # Pipe-delimited record
    results+=("${short}|${day}|${week}|${month}|${year}|${code}|${delta}|${subject}")

    printf '\r  [%d/%d] %s  %s' "$processed" "$to_process" "$short" "$day" >&2
done

printf '\r%-60s\r' '' >&2
echo "Done." >&2
echo "" >&2

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
format_delta() {
    local d=$1
    if [[ $d -gt 0 ]]; then echo "+${d}"
    else                     echo "${d}"
    fi
}

# Emit a grouped table. Uses the latest commit in each period for that row's stats.
#   $1 = column header ("Date", "Week", "Month", or "Year")
#   $2 = field name:  "day", "week", "month", or "year"
emit_grouped() {
    local header=$1 field=$2

    printf '%-12s  %10s  %10s\n' "$header" "Code" "Delta"
    printf '%-12s  %10s  %10s\n' "------------" "----------" "----------"

    local prev_group="" group_code=0 last_before=0

    for r in "${results[@]}"; do
        IFS='|' read -r hash day week month year code delta subject <<< "$r"

        local key
        case "$field" in
            day)   key=$day   ;;
            week)  key=$week  ;;
            month) key=$month ;;
            year)  key=$year  ;;
        esac

        if [[ "$key" != "$prev_group" && -n "$prev_group" ]]; then
            local d=$((group_code - last_before))
            printf '%-12s  %10s  %10s\n' "$prev_group" "$group_code" "$(format_delta "$d")"
            last_before=$group_code
        fi

        prev_group="$key"
        group_code=$code
    done

    # Emit final group
    if [[ -n "$prev_group" ]]; then
        local d=$((group_code - last_before))
        printf '%-12s  %10s  %10s\n' "$prev_group" "$group_code" "$(format_delta "$d")"
    fi
}

# ---------------------------------------------------------------------------
# Display results
# ---------------------------------------------------------------------------
case "$SUMMARIZE" in
    commit)
        printf '%-10s  %-12s  %10s  %10s  %s\n' \
            "Hash" "Date" "Code" "Delta" "Subject"
        printf '%-10s  %-12s  %10s  %10s  %s\n' \
            "----------" "------------" "----------" "----------" \
            "------------------------------------------------------------"

        for r in "${results[@]}"; do
            IFS='|' read -r hash day week month year code delta subject <<< "$r"
            printf '%-10s  %-12s  %10s  %10s  %.60s\n' \
                "$hash" "$day" "$code" "$(format_delta "$delta")" "$subject"
        done
        ;;
    day)   emit_grouped "Date"  day   ;;
    week)  emit_grouped "Week"  week  ;;
    month) emit_grouped "Month" month ;;
    year)  emit_grouped "Year"  year  ;;
esac

# cloc-history

Track lines of code across every commit in a git repository's history using [cloc](https://github.com/AlDanial/cloc).

Shows code line counts and deltas in chronological order, with optional grouping by day, week, month, or year.

## Prerequisites

- **bash** 3.2+
- **git** 2.5+ (uses `git worktree`)
- **[cloc](https://github.com/AlDanial/cloc)**

```bash
# macOS
brew install cloc

# Debian / Ubuntu
sudo apt install cloc
```

## Installation

```bash
# Clone and make executable
git clone https://github.com/fewtrell/cloc-history.git
cd cloc-history
chmod +x cloc-history.sh

# Or just download the script
curl -O https://raw.githubusercontent.com/fewtrell/cloc-history/main/cloc-history.sh
chmod +x cloc-history.sh
```

## Usage

Run from inside any git repository with a clean working tree:

```
Usage: cloc-history.sh [OPTIONS] [-- CLOC_OPTIONS...]

Options:
  -h, --help              Show this help message
  -s, --summarize MODE    Group results: "commit" (default), "day", "week",
                          "month", or "year"
  -n, --max-commits N     Process only the last N commits
  --all-parents           Follow all parents at merges (default: first-parent only)

Everything after -- is passed directly to cloc.
```

## Examples

### Every commit (default)

```bash
./cloc-history.sh
```

```
Hash        Date              Code       Delta  Subject
----------  ------------  ----------  ----------  ---------------------------
a1b2c3d     2024-01-15          342        +342  Initial commit
d4e5f6g     2024-01-16          587        +245  Add user authentication
e7f8a9b     2024-01-18          510         -77  Remove dead code
```

### Summarize by month

```bash
./cloc-history.sh -s month
```

```
Month             Code       Delta
------------  ----------  ----------
2024-01              510        +510
2024-02              830        +320
2024-03             1102        +272
```

### Summarize by year

```bash
./cloc-history.sh -s year
```

```
Year              Code       Delta
------------  ----------  ----------
2023              4200        +4200
2024              8750        +4550
2025             12300        +3550
```

### Filter with cloc options

Everything after `--` is passed to cloc:

```bash
# Exclude directories
./cloc-history.sh -- --exclude-dir=vendor,node_modules,dist

# Only count specific languages
./cloc-history.sh -- --include-lang=Python,JavaScript,TypeScript

# Exclude file extensions
./cloc-history.sh -s week -- --exclude-ext=json,yaml,xml

# Limit to last 100 commits
./cloc-history.sh -n 100
```

## How it works

1. Validates the repository has no uncommitted changes
2. Creates a temporary [git worktree](https://git-scm.com/docs/git-worktree) (your working directory is never touched)
3. For each commit, checks out the code in the worktree and runs `cloc --vcs=git` to count only git-tracked files
4. When summarizing by period, skips intermediate commits and only runs cloc on the last commit in each period
5. Cleans up the worktree on exit

## Performance

Each commit requires a `git checkout` and a full `cloc` run, so large repositories can take a while. Use `-n` to limit commits, or use period summarization (`-s week`, `-s month`, `-s year`) which automatically skips intermediate commits.

## License

[MIT](LICENSE)

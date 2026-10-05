#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: $0 SCAN.json [REPORT.json]" >&2
    exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage
scan_path=$1
output_path=${2:-"${scan_path%.*}.cleanup.json"}

command -v duckdb >/dev/null 2>&1 || {
    echo "duckdb is required; install it with: brew install duckdb" >&2
    exit 1
}
[[ -f "$scan_path" ]] || {
    echo "scan file not found: $scan_path" >&2
    exit 1
}
[[ "$scan_path" != "$output_path" ]] || {
    echo "refusing to overwrite the scan file" >&2
    exit 1
}

output_dir=$(dirname "$output_path")
[[ -d "$output_dir" ]] || {
    echo "output directory not found: $output_dir" >&2
    exit 1
}

tmp_output=$(mktemp "$output_path.tmp.XXXXXX")
cleanup() { rm -f "$tmp_output"; }
trap cleanup EXIT

# Escape a path for a SQL string literal. DuckDB accepts doubled single quotes.
sql_scan_path=$(printf '%s' "$scan_path" | sed "s/'/''/g")

# The scan is one large JSON document, not JSONL. Keep this analysis read-only:
# it creates no database and never touches any candidate path.
duckdb -list -noheader <<SQL > "$tmp_output"
SET threads = 2;
SET preserve_insertion_order = false;

WITH RECURSIVE
raw AS (
    SELECT *
    FROM read_json(
        '$sql_scan_path',
        format = 'unstructured',
        records = true,
        maximum_object_size = 1073741824,
        columns = {
            format: 'VARCHAR',
            schemaVersion: 'INTEGER',
            pathMode: 'VARCHAR',
            truncated: 'BOOLEAN',
            scan: 'STRUCT(coverage VARCHAR, finishedAt VARCHAR, reportedUnreadableDirectories BIGINT, startedAt VARCHAR, state VARCHAR)',
            nodes: 'STRUCT(id BIGINT, parentId BIGINT, name VARCHAR, isDirectory BOOLEAN, allocatedBytes VARCHAR)[]'
        }
    )
),
nodes AS (
    SELECT
        node.id AS id,
        node.parentId AS parent_id,
        node.name AS name,
        node.isDirectory AS is_directory,
        CAST(node.allocatedBytes AS BIGINT) AS allocated_bytes
    FROM raw, unnest(nodes) AS t(node)
),
paths AS (
    SELECT
        id, parent_id, name, is_directory, allocated_bytes,
        CAST('.' AS VARCHAR) AS path
    FROM nodes
    WHERE parent_id IS NULL

    UNION ALL

    SELECT
        child.id, child.parent_id, child.name, child.is_directory,
        child.allocated_bytes,
        CASE
            WHEN parent.path = '.' THEN './' || child.name
            ELSE parent.path || '/' || child.name
        END AS path
    FROM nodes AS child
    JOIN paths AS parent ON child.parent_id = parent.id
),
rules(id, category, label, confidence, risk, action, reason) AS (
    VALUES
        (
            'docker-vm', 'container_storage', 'Docker virtual disk', 'high', 'high',
            'Use Docker Desktop storage cleanup or docker system df/prune; never delete Docker.raw directly.',
            'A virtual disk is large, but it may contain active images, containers, or volumes.'
        ),
        (
            'podman-vm', 'container_storage', 'Podman virtual machine', 'high', 'high',
            'Use podman system df/prune or remove the machine only after confirming it is unused.',
            'A VM image is not a disposable cache and may contain active container data.'
        ),
        (
            'homebrew-cache', 'cache', 'Homebrew download cache', 'high', 'low',
            'Run brew cleanup --dry-run, then brew cleanup after reviewing the list.',
            'Homebrew can redownload cached installers and identifies its own safe cleanup set.'
        ),
        (
            'homebrew-caskroom', 'package_cache', 'Homebrew Caskroom installers', 'medium', 'medium',
            'Only versions older than the installed cask are reclaimable (brew cleanup). The installed version''s installer stays until brew uninstall --cask; brew upgrade replaces it with a same-size one, so it saves nothing.',
            'Homebrew keeps the installer of the installed cask version for uninstall and reinstall.'
        ),
        (
            'simulator-cache', 'developer_cache', 'CoreSimulator cache', 'high', 'low',
            'Run xcrun simctl delete unavailable and remove only runtimes no longer needed.',
            'Simulator caches can be regenerated, but active development runtimes should be kept.'
        ),
        (
            'simulator-runtime', 'developer_storage', 'iOS Simulator runtime (machine-wide)', 'high', 'medium',
            'Remove with xcrun simctl runtime delete, which needs full Xcode (check xcode-select -p). Without Xcode, leave it or decide manually; never delete files under /System or /Library by hand.',
            'Runtimes stay after Xcode is removed, but only Apple''s tooling can unregister them safely.'
        ),
        (
            'xcode-derived-data', 'developer_cache', 'Xcode DerivedData', 'high', 'low',
            'Use Xcode settings or delete selected DerivedData after closing Xcode.',
            'DerivedData is rebuildable, but an active build can be interrupted.'
        ),
        (
            'developer-cache', 'developer_cache', 'Developer/build cache', 'medium', 'medium',
            'Use the owning tool’s clean command, then remove only confirmed stale artifacts.',
            'Build and dependency caches are usually rebuildable but may support active worktrees.'
        ),
        (
            'git-pack', 'developer_storage', 'Git pack history', 'high', 'medium',
            'Run git gc inside the repository and remove stale worktrees through Git; never delete pack files manually.',
            'Git can compact redundant objects, but unreachable history may still be needed for recovery.'
        ),
        (
            'model-storage', 'model_storage', 'Local AI model', 'medium', 'medium',
            'Review whether the owning app still uses the model, then remove it through that app or move it to external storage.',
            'Models are large but may be intentionally kept for offline inference.'
        ),
        (
            'agent-logs', 'logs', 'Agent history/logs', 'medium', 'medium',
            'Review retention needs and back up or remove old logs with the owning tool stopped.',
            'Logs may contain useful history or sensitive prompts.'
        ),
        (
            'user-trash', 'trash', 'User Trash', 'high', 'low',
            'Empty Trash after reviewing the listed items.',
            'These files are already in Trash and are the clearest user-controlled reclaimable space.'
        ),
        (
            'user-cache', 'cache', 'User application cache', 'medium', 'low',
            'Quit the owning app, review the paths, and remove only caches confirmed safe to regenerate.',
            'Caches are generally rebuildable, but some apps use cache directories for active state.'
        ),
        (
            'user-download', 'user_data', 'Downloads item', 'medium', 'high',
            'Review and move or delete only files the owner no longer needs.',
            'Downloads are user data, not automatically disposable cache.'
        )
),
classified AS (
    SELECT
        paths.*,
        CASE
            WHEN path LIKE './Users/%/Library/Containers/com.docker.docker/Data/vms/%/Docker.raw'
                THEN 'docker-vm'
            WHEN path LIKE './Users/%/Library/Application Support/%/containers/podman/machine/%'
                THEN 'podman-vm'
            WHEN path LIKE './Users/%/Library/Caches/Homebrew/downloads/%'
                THEN 'homebrew-cache'
            WHEN path LIKE './opt/homebrew/Caskroom/%'
                THEN 'homebrew-caskroom'
            WHEN path LIKE './Users/%/Library/Developer/CoreSimulator/Caches/%'
                THEN 'simulator-cache'
            WHEN path LIKE './System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/%'
                OR path LIKE './Library/Developer/CoreSimulator/%'
                THEN 'simulator-runtime'
            WHEN path LIKE './Users/%/Library/Developer/Xcode/DerivedData/%'
                THEN 'xcode-derived-data'
            WHEN path LIKE './Users/%/.gradle/caches/%'
                OR path LIKE './Users/%/node_modules/%'
                OR path LIKE './Users/%/.scratch/%/build/%'
                OR path LIKE './Users/%/build/%'
                THEN 'developer-cache'
            WHEN path LIKE './Users/%/.git/objects/pack/%'
                THEN 'git-pack'
            WHEN lower(path) LIKE './users/%.gguf'
                OR lower(path) LIKE './users/%.onnx'
                OR lower(path) LIKE './users/%.onnx_data'
                OR lower(path) LIKE './users/%.pt'
                OR lower(path) LIKE './users/%/mlmodelc/%'
                THEN 'model-storage'
            WHEN path LIKE './Users/%/.codex/logs_%'
                OR path LIKE './Users/%/.codex/thread_history_%'
                THEN 'agent-logs'
            WHEN path LIKE './Users/%/.Trash/%'
                THEN 'user-trash'
            WHEN path LIKE './Users/%/Library/Caches/%'
                THEN 'user-cache'
            WHEN path LIKE './Users/%/Downloads/%'
                THEN 'user-download'
            ELSE NULL
        END AS rule_id
    FROM paths
    WHERE NOT is_directory
),
candidate_files AS (
    SELECT
        classified.*,
        rules.* EXCLUDE (id),
        CASE
            WHEN classified.rule_id = 'docker-vm'
                THEN classified.path
            WHEN classified.rule_id = 'podman-vm'
                THEN classified.path
            WHEN classified.rule_id = 'homebrew-cache'
                THEN regexp_extract(classified.path, '^(.*?/Library/Caches/Homebrew/downloads)', 1)
            WHEN classified.rule_id = 'homebrew-caskroom'
                THEN regexp_extract(classified.path, '^(.*?/Caskroom/[^/]+/[^/]+)', 1)
            WHEN classified.rule_id = 'simulator-cache'
                THEN regexp_extract(classified.path, '^(.*?/CoreSimulator/Caches/[^/]+)', 1)
            WHEN classified.rule_id = 'simulator-runtime'
                THEN coalesce(
                    nullif(regexp_extract(classified.path, '^(.*?/com_apple_MobileAsset_iOSSimulatorRuntime/[^/]+)', 1), ''),
                    regexp_extract(classified.path, '^(.*?/CoreSimulator/[^/]+/[^/]+)', 1)
                )
            WHEN classified.rule_id = 'xcode-derived-data'
                THEN regexp_extract(classified.path, '^(.*?/DerivedData/[^/]+)', 1)
            WHEN classified.rule_id = 'developer-cache'
                 AND classified.path LIKE '%/.gradle/caches/%'
                THEN regexp_extract(classified.path, '^(.*?/.gradle/caches)', 1)
            WHEN classified.rule_id = 'developer-cache'
                 AND classified.path LIKE '%/node_modules/%'
                THEN regexp_extract(classified.path, '^(.*?/node_modules)', 1)
            WHEN classified.rule_id = 'developer-cache'
                 AND classified.path LIKE '%/build/%'
                THEN regexp_extract(classified.path, '^(.*?/build)', 1)
            WHEN classified.rule_id = 'git-pack'
                THEN regexp_extract(classified.path, '^(.*?/.git/objects/pack)', 1)
            WHEN classified.rule_id = 'model-storage'
                 AND classified.path LIKE '%/mlmodelc/%'
                THEN regexp_extract(classified.path, '^(.*?/mlmodelc)', 1)
            WHEN classified.rule_id = 'user-cache'
                THEN regexp_extract(classified.path, '^(.*?/Library/Caches/[^/]+)', 1)
            WHEN classified.rule_id = 'user-trash'
                THEN regexp_extract(classified.path, '^(.*?/.Trash)', 1)
            ELSE classified.path
        END AS scope_path
    FROM classified
    JOIN rules ON rules.id = classified.rule_id
),
ranked_files AS (
    SELECT
        candidate_files.*,
        row_number() OVER (
            PARTITION BY rule_id
            ORDER BY allocated_bytes DESC, path
        ) AS rank_in_rule
    FROM candidate_files
),
scope_totals AS (
    SELECT
        rule_id,
        scope_path,
        COUNT(*) AS file_count,
        SUM(allocated_bytes) AS allocated_bytes
    FROM candidate_files
    GROUP BY rule_id, scope_path
),
ranked_scopes AS (
    SELECT
        scope_totals.*,
        row_number() OVER (
            PARTITION BY rule_id
            ORDER BY allocated_bytes DESC, scope_path
        ) AS rank_in_rule
    FROM scope_totals
),
finding_rows AS (
    SELECT
        rule_id AS id,
        any_value(category) AS category,
        any_value(label) AS label,
        any_value(confidence) AS confidence,
        any_value(risk) AS risk,
        any_value(action) AS action,
        any_value(reason) AS reason,
        COUNT(*) AS file_count,
        SUM(allocated_bytes) AS allocated_bytes,
        (
            SELECT to_json(list(
                struct_pack(
                    id := top_file.id,
                    path := top_file.path,
                    allocatedBytes := CAST(top_file.allocated_bytes AS VARCHAR)
                )
                ORDER BY top_file.allocated_bytes DESC, top_file.path
            ))
            FROM ranked_files AS top_file
            WHERE top_file.rule_id = ranked_files.rule_id
              AND top_file.rank_in_rule <= 20
        ) AS items,
        COALESCE(
            (
                SELECT to_json(list(
                    struct_pack(
                        path := top_scope.scope_path,
                        allocatedBytes := CAST(top_scope.allocated_bytes AS VARCHAR),
                        fileCount := top_scope.file_count
                    )
                    ORDER BY top_scope.allocated_bytes DESC, top_scope.scope_path
                ))
                FROM ranked_scopes AS top_scope
                WHERE top_scope.rule_id = ranked_files.rule_id
                  AND top_scope.rank_in_rule <= 10
            ),
            json('[]')
        ) AS scopes
    FROM ranked_files
    GROUP BY rule_id
),
source_info AS (
    SELECT
        any_value(format) AS format,
        any_value(schemaVersion) AS schema_version,
        any_value(pathMode) AS path_mode,
        any_value(truncated) AS truncated,
        any_value(scan.state) AS state,
        any_value(scan.coverage) AS coverage,
        any_value(scan.startedAt) AS started_at,
        any_value(scan.finishedAt) AS finished_at,
        any_value(scan.reportedUnreadableDirectories) AS unreadable_directories
    FROM raw
    WHERE format = 'opendisk.scan' AND schemaVersion = 1
),
root_info AS (
    SELECT allocated_bytes AS root_bytes
    FROM nodes
    WHERE parent_id IS NULL
    LIMIT 1
),
totals AS (
    SELECT
        COUNT(*) AS candidate_files,
        COALESCE(SUM(allocated_bytes), 0) AS candidate_bytes
    FROM candidate_files
),
unclassified AS (
    SELECT
        COUNT(*) FILTER (WHERE allocated_bytes >= 1073741824) AS large_file_count,
        COALESCE(
            (
                SELECT to_json(list(
                    struct_pack(
                        id := large.id,
                        path := large.path,
                        allocatedBytes := CAST(large.allocated_bytes AS VARCHAR)
                    )
                    ORDER BY large.allocated_bytes DESC, large.path
                ))
                FROM (
                    SELECT id, path, allocated_bytes
                    FROM classified
                    WHERE rule_id IS NULL AND allocated_bytes >= 1073741824
                    ORDER BY allocated_bytes DESC, path
                    LIMIT 20
                ) AS large
            ),
            json('[]')
        ) AS large_files
    FROM classified
),
findings AS (
    SELECT COALESCE(
        (
            SELECT to_json(list(
                struct_pack(
                    id := row.id,
                    category := row.category,
                    label := row.label,
                    confidence := row.confidence,
                    risk := row.risk,
                    allocatedBytes := CAST(row.allocated_bytes AS VARCHAR),
                    fileCount := row.file_count,
                    action := row.action,
                    reason := row.reason,
                    scopes := row.scopes,
                    items := row.items
                )
                ORDER BY row.allocated_bytes DESC, row.id
            ))
            FROM finding_rows AS row
        ),
        json('[]')
    ) AS value
)
SELECT to_json(
    struct_pack(
        format := 'opendisk.cleanup',
        schemaVersion := 1,
        analyzer := 'path_rules_v1',
        readOnly := true,
        source := struct_pack(
            format := source_info.format,
            schemaVersion := source_info.schema_version,
            pathMode := source_info.path_mode,
            truncated := source_info.truncated,
            state := source_info.state,
            coverage := source_info.coverage,
            startedAt := source_info.started_at,
            finishedAt := source_info.finished_at,
            reportedUnreadableDirectories := source_info.unreadable_directories,
            rootAllocatedBytes := CAST(root_info.root_bytes AS VARCHAR)
        ),
        totals := struct_pack(
            candidateBytes := CAST(totals.candidate_bytes AS VARCHAR),
            candidateFiles := totals.candidate_files,
            unclassifiedLargeFiles := unclassified.large_file_count
        ),
        findings := findings.value,
        unclassifiedLargeFiles := unclassified.large_files,
        warnings := json(
            '["Path rules are heuristics, not proof that deletion is safe.","Directory totals are inclusive; candidate bytes count files only.","The source scan is best-effort and may omit unreadable content.","Review every action and use the owning tool instead of deleting VM disks or Git internals directly."]'
        )
    )
) AS report
FROM source_info, root_info, totals, unclassified, findings;
SQL

[[ -s "$tmp_output" ]] || {
    echo "duckdb produced an empty cleanup report" >&2
    exit 1
}

mv "$tmp_output" "$output_path"
trap - EXIT
printf '%s\n' "$output_path"

#!/usr/bin/env nu

use std/log

const PYTHON_PROJECT_FILES = [pyproject.toml setup.py]
const IGNORED_DIRECTORY_NAMES = [
    .git node_modules vendor .venv __pycache__ .cache
    dist build out .next .nuxt coverage
]
const GENERATED_DIRECTORY_NAMES = [
    .git node_modules vendor .venv __pycache__ .cache .next .nuxt coverage
]
const IGNORED_TEST_PATH_NAMES = [
    .git node_modules vendor .venv __pycache__ .cache dist build out .next .nuxt coverage
]
const PYRIGHT_DEFAULT_EXCLUDES = [
    '**/.git'
    '**/node_modules'
    '**/__pycache__'
    '**/.venv'
    '**/.cache'
    '**/dist'
    '**/build'
]

def project []: nothing -> path {
    $env.QUALITY_GATE_PROJECT_DIR? | default '.' | path expand
}

def quality-gate-root []: nothing -> path {
    $env.QUALITY_GATE_ROOT? | default ($env.QUALITY_GATE_PROJECT_DIR? | default '.') | path expand
}

def has-project-file [files: list<string>]: nothing -> bool {
    $files | any {|file| ($file | path exists) }
}

def project-languages [directory: string]: nothing -> list<string> {
    mut languages = []

    if (($directory | path join 'go.mod') | path exists) {
        $languages = ($languages | append 'go')
    }
    if (['pyproject.toml' 'setup.py'] | any {|file| ($directory | path join $file) | path exists}) {
        $languages = ($languages | append 'python')
    }
    if ((($directory | path join 'package.json') | path exists) and (($directory | path join 'tsconfig.json') | path exists)) {
        $languages = ($languages | append 'typescript')
    }

    $languages
}

def changed-files []: nothing -> list<string> {
    let scope = (project)
    let raw = ($env.QUALITY_GATE_CHANGED_FILES? | default '')
    if ($raw | is-empty) {
        []
    } else {
        $raw
        | lines
        | where {|file| ($file | str trim | is-not-empty) }
        | each {|file|
            if ($file | path expand | str starts-with '/') {
                $file | path expand
            } else {
                $scope | path join $file | path expand
            }
        }
    }
}

def ignored-project-path [directory: string, scope: string]: nothing -> bool {
    let relative = ($directory | path relative-to $scope)
    let parts = ($relative | path split)
    $parts | any {|part|
        ($part | str starts-with '.') or ($part in $IGNORED_DIRECTORY_NAMES)
    }
}

def marker-files-from-git [scope: path]: nothing -> oneof<list<path>, nothing> {
    let root_result = (do { ^git -C $scope rev-parse --show-toplevel } | complete)
    if $root_result.exit_code != 0 {
        return null
    }
    let git_root = $root_result.stdout | str trim | path expand
    let files_result = (do {
        ^git -c core.excludesFile=/dev/null -C $git_root ls-files --cached --others --exclude-standard
    } | complete)
    if $files_result.exit_code != 0 {
        return null
    }
    let scope_path = $scope | path expand
    $files_result.stdout
    | lines
    | where {|file| ($file | str trim | is-not-empty) }
    | each {|file| $git_root | path join $file | path expand }
    | where {|file|
        $file == $scope_path or ($file | str starts-with $'($scope_path)/')
    }
    | where {|file| ($file | path basename) in ['go.mod' 'pyproject.toml' 'setup.py' 'package.json' 'tsconfig.json'] }
}

def marker-files-from-glob [scope: path]: nothing -> list<path> {
    [
        (glob --no-dir ($'($scope)/**/go.mod'))
        (glob --no-dir ($'($scope)/**/pyproject.toml'))
        (glob --no-dir ($'($scope)/**/setup.py'))
        (glob --no-dir ($'($scope)/**/package.json'))
        (glob --no-dir ($'($scope)/**/tsconfig.json'))
    ] | flatten
}

def project-directories []: nothing -> list<string> {
    let scope = (project)
    validate-quality-gate-exclusions
    let marker_files = (marker-files-from-git $scope)
    let marker_files = if $marker_files == null {
        marker-files-from-glob $scope
        | where {|file| not (ignored-project-path ($file | path dirname) $scope) }
    } else {
        $marker_files
    }

    let directories = $marker_files
    | each {|file| $file | path dirname }
    | uniq
    | where {|directory| not (ignored-project-path $directory $scope) }
    | where {|directory| not (quality-gate-path-excluded $directory) }
    | where {|directory| (project-languages $directory) | is-not-empty }
    | sort

    let changed = changed-files
    if ($changed | is-empty) {
        $directories
    } else {
        $directories | where {|directory|
            let deeper = $directories | where {|other| $other | str starts-with $'($directory)/' }
            $changed | any {|file|
                let inside = $file == $directory or ($file | str starts-with ($'($directory)/'))
                let owned_deeper = $deeper | any {|other| $file == $other or ($file | str starts-with ($'($other)/')) }
                $inside and not $owned_deeper
            }
        }
    }
}

def local-test-files [patterns: list<string>]: nothing -> list<string> {
    let scope = (project)
    $patterns
    | each {|pattern| glob --no-dir ($'($scope)/($pattern)' | path expand) }
    | flatten
    | where {|file|
        let parts = (($file | path relative-to $scope) | path split)
        not ($parts | any {|part| $part in $IGNORED_TEST_PATH_NAMES })
    }
    | uniq
    | sort
}

def require-local-tests [language: string] {
    let patterns = match $language {
        python => ['**/test_*.py' '**/*_test.py']
        go => ['**/*_test.go']
        typescript => [
            '**/*.test.ts'
            '**/*.test.tsx'
            '**/*.test.mts'
            '**/*.test.cts'
            '**/*.test.js'
            '**/*.test.jsx'
            '**/*.spec.ts'
            '**/*.spec.tsx'
            '**/*.spec.mts'
            '**/*.spec.cts'
            '**/*.spec.js'
            '**/*.spec.jsx'
            '**/*.spec.vue'
        ]
        _ => []
    }

    if (local-test-files $patterns | is-empty) {
        error make {msg: 'finding: No local tests were found'}
    }
}

def skip [language: string] {
    log warning $'No ($language) project was found in ($env.PWD); skipping.'
}

def report-only []: nothing -> bool {
    let mode = $env.QUALITY_GATE_MODE? | default 'block'
    if $mode != 'report' {
        return false
    }
    let until = $env.QUALITY_GATE_REPORT_UNTIL? | default ''
    if ($until | is-empty) {
        error make {msg: 'QUALITY_GATE_MODE=report requires QUALITY_GATE_REPORT_UNTIL (maximum 45 days).'}
    }
    let deadline = try {
        $until | into datetime
    } catch {
        error make {msg: $'Invalid QUALITY_GATE_REPORT_UNTIL: ($until). Use YYYY-MM-DD.'}
    }
    let now = date now
    if $deadline < $now {
        error make {msg: $'Quality Gate report-only period expired on ($until). Remove QUALITY_GATE_MODE=report or set a future approved date.'}
    }
    if $deadline > ($now + 45day) {
        error make {msg: 'QUALITY_GATE_REPORT_UNTIL cannot be more than 45 days in the future.'}
    }
    let in_ci = (($env.QUALITY_GATE_CI? | default '') == 'true') or (($env.CI? | default '') | is-not-empty)
    let ci_project = $env.QUALITY_GATE_REPORT_PROJECT? | default ($env.CI_PROJECT_PATH? | default '')
    if $in_ci and ($ci_project | is-empty) {
        error make {msg: 'Report-only mode in CI requires the adapter to identify the project (QUALITY_GATE_REPORT_PROJECT).'}
    }
    if $in_ci {
        let policy_file = $env.QUALITY_GATE_REPORT_POLICY? | default ''
        if ($policy_file | is-empty) or not ($policy_file | path exists) {
            error make {msg: 'Report-only mode is not allowed in CI without the central policy file.'}
        }
        let policy = open $policy_file
        let approved = ($policy.projects? | default [])
            | where {|entry| $entry.project == $ci_project and $entry.until == $until }
        if ($approved | is-empty) {
            error make {msg: $'Project ($ci_project) is not approved for report-only mode until ($until).'}
        }
    }
    true
}

def capture [command: string, arguments: list<string>]: nothing -> record {
    with-env {NO_COLOR: '1', TERM: 'dumb'} {
        hide-env --ignore-errors FORCE_COLOR
        hide-env --ignore-errors CLICOLOR_FORCE
        run-external $command ...$arguments | complete
    }
}

# Tool output may carry terminal escape sequences (colors, OSC 8 hyperlinks)
# and other control characters. They are invalid in XML 1.0, so reports must
# never contain them.
def strip-terminal-codes [value: string]: nothing -> string {
    $value
    | str replace --all --regex '\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)' ''
    | str replace --all --regex '\x1b\[[0-9;?]*[ -/]*[@-~]' ''
    | str replace --all --regex '[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]' ''
}

def record-output [text: string] {
    let output_file = ($env.QUALITY_GATE_CHECK_OUTPUT? | default null)
    if $output_file == null or ($text | is-empty) { return }
    let previous = if ($output_file | path exists) { open --raw $output_file } else { '' }
    ($previous + (strip-terminal-codes $text) + (char nl)) | save --force $output_file
}

def finding-description [name: string]: nothing -> string {
    match $name {
        'go build' => 'Go compilation reported errors. Review the compiler diagnostics below.'
        'go vet' => 'Go vet reported issues. Review the diagnostics below.'
        'golangci-lint' => 'Go lint reported issues. Review the diagnostics below.'
        'go test' => 'Go tests did not pass. Review the build and test diagnostics below.'
        'basedpyright' => 'Python typecheck reported errors. Review the diagnostics below.'
        'tsc' | 'vue-tsc' => 'TypeScript typecheck reported errors. Review the diagnostics below.'
        'uv pytest' | 'npm test' | 'pnpm test' => 'The project test command did not pass. Review the diagnostics below.'
        _ => 'The check reported failures. Review the diagnostics below.'
    }
}

# A check reports `finding` only when the tool exits with one of `finding-codes`
# (the exit codes that mean "the code violates the policy"). Every other
# non-zero exit means the tool could not run and is reported as `engine`.
# Tests run consumer code, so any failure of a test runner is a `finding`.
def run-check [
    name: string
    command: string
    arguments: list<string>
    --finding-codes: list<int>
    --any-failure-is-finding
    --engine-markers: list<string>
] {
    log info $'Running ($name)...'
    let result = capture $command $arguments

    if ($result.stdout | is-not-empty) {
        let output = ($result.stdout | str trim)
        print $output
        record-output $output
    }
    if ($result.stderr | is-not-empty) {
        let output = ($result.stderr | str trim)
        print -e $output
        record-output $output
    }
    if $result.exit_code != 0 {
        let codes = $finding_codes | default [1]
        let output = $'($result.stdout)($result.stderr)'
        let engine_marker = ($engine_markers | default []) | any {|marker| $output | str contains $marker }
        let category = if $engine_marker {
            'engine'
        } else if $any_failure_is_finding or ($result.exit_code in $codes) {
            'finding'
        } else {
            'engine'
        }
        let explanation = if $category == engine and $name in ['uv sync' 'npm ci' 'pnpm install'] {
            'Dependency installation did not complete. Check the execution environment and diagnostics below.'
        } else if $category == engine {
            'The command could not complete. Check the execution environment and diagnostics below.'
        } else {
            finding-description $name
        }
        error make {msg: $'($category): ($name): ($explanation) Exit code: ($result.exit_code).'}
    }
}

def format-check-failure [tool: string, result: record, message: string] {
    record-output ($result.stdout | str trim)
    record-output ($result.stderr | str trim)
    if $result.exit_code == 1 {
        error make {msg: $'finding: ($message)'}
    }
    error make {msg: $'engine: ($tool) failed with exit code ($result.exit_code) while checking formatting'}
}

def warn-local-quality-config [files: list<string>] {
    let found = $files | where {|file| ($file | path exists) }
    if ($found | is-not-empty) {
        log warning $'Ignoring local quality configuration (($found | str join ", ")); the central Quality Gate configuration is mandatory.'
    }
}

def quality-gate-exclude-patterns []: nothing -> list<string> {
    let file = quality-gate-root | path join .quality-gate exclude
    if not ($file | path exists) {
        return []
    }
    open --raw $file
    | lines
    | each {|line| $line | str trim }
    | where {|line| ($line | is-not-empty) and not ($line | str starts-with '#') }
}

def git-repository-root [scope: path]: nothing -> oneof<path, nothing> {
    let result = (do { ^git -C $scope rev-parse --show-toplevel } | complete)
    if $result.exit_code == 0 {
        $result.stdout | str trim | path expand
    } else {
        null
    }
}

def git-repository-files [scope: path]: nothing -> list<string> {
    let root = (git-repository-root $scope)
    if $root == null {
        return []
    }
    let result = (do {
        ^git -c core.excludesFile=/dev/null -C $root ls-files --cached --others --exclude-standard
    } | complete)
    if $result.exit_code != 0 {
        []
    } else {
        let scope_path = $scope | path expand
        $result.stdout
        | lines
        | where {|file| ($file | str trim | is-not-empty) }
        | each {|file| $root | path join $file | path expand }
        | where {|file|
            $file == $scope_path or ($file | str starts-with $'($scope_path)/')
        }
    }
}

def git-excluded-relative [paths: list<string>]: nothing -> list<string> {
    let patterns = quality-gate-exclude-patterns
    if ($patterns | is-empty) or ($paths | is-empty) {
        return []
    }
    let temporary = (mktemp --directory | str trim)
    try {
        ^git init --quiet $temporary
        let exclude = $temporary | path join .git info exclude
        $patterns | str join (char nl) | save --force $exclude
        let input = ($paths | str join (char nl)) + (char nl)
        let result = ($input | ^git -c core.excludesFile=/dev/null -C $temporary check-ignore --no-index --stdin | complete)
        if $result.exit_code == 0 {
            $result.stdout | lines | where {|path| ($path | str trim | is-not-empty) }
        } else {
            []
        }
    } finally {
        rm --recursive --force $temporary
    }
}

def validate-quality-gate-exclusions []: nothing -> nothing {
    let patterns = quality-gate-exclude-patterns
    let broad = $patterns | where {|pattern|
        ($pattern | str trim) in ['' '*' '**' '**/*' '.' './' '/']
    }
    if ($broad | is-not-empty) {
        error make {msg: $'Invalid .quality-gate/exclude patterns: ($broad | str join ", "). Broad patterns cannot disable the Quality Gate.'}
    }

    let scope = quality-gate-root
    let files = git-repository-files $scope
    let root_exclude = $scope | path join .quality-gate exclude | path expand
    let nested = $files
        | where {|file| $file != $root_exclude }
        | where {|file| ($file | path relative-to $scope | path split) | any {|part| $part == '.quality-gate' }}
        | where {|file| ($file | path basename) == 'exclude' }
    if ($nested | is-not-empty) {
        error make {msg: 'The .quality-gate/exclude file is allowed only at the repository root.'}
    }
    if ($files | is-empty) or ($patterns | is-empty) {
        return
    }
    let code = $files | where {|file|
        let extension = (($file | path parse).extension? | default '' | str lowercase)
        $extension in [
            py pyi go ts tsx mts cts js jsx vue
        ]
    }
    let relative = $code | each {|file| $file | path relative-to $scope }
    let excluded = git-excluded-relative $relative
    if ($code | is-empty) { return }
    let percentage = (($excluded | length) * 100 / ($code | length))
    if $percentage > 30 {
        error make {msg: $'.quality-gate/exclude excludes ($excluded | length) of ($code | length) code files (($percentage | math round)%). The maximum is 30%.'}
    }
}

def quality-gate-path-excluded [candidate: path]: nothing -> bool {
    let relative = $candidate | path relative-to (quality-gate-root)
    (git-excluded-relative [$relative $'($relative)/'] | is-not-empty)
}

# Projects of `language` that live inside the current project. Their files are
# checked as part of that nested project, not again as part of the outer one.
def nested-project-directories [language: string]: nothing -> list<path> {
    let scope = (project)
    let markers = (marker-files-from-git $scope) | default (marker-files-from-glob $scope)
    $markers
    | each {|file| $file | path dirname }
    | uniq
    | where {|directory| $directory != $scope and not (ignored-project-path $directory $scope) }
    | where {|directory| $language in (project-languages $directory) }
}

def quality-gate-files [extensions: list<string>, --language: string = '']: nothing -> list<string> {
    let scope = project
    let root = quality-gate-root
    let tracked = git-repository-files $scope
    let files = if ($tracked | is-empty) {
        glob --no-dir ($'($scope)/**/*')
            | where {|file| not (ignored-project-path ($file | path dirname) $scope) }
    } else {
        $tracked
    }
    let excluded = git-excluded-relative ($files | each {|file| $file | path relative-to $root })
        | each {|file| $root | path join $file | path expand }
    let nested = if ($language | is-empty) { [] } else { nested-project-directories $language }
    $files
    | where {|file|
        let extension = (($file | path parse).extension? | default '' | str lowercase)
        $extension in $extensions
    }
    | where {|file| $file not-in $excluded }
    | where {|file|
        not (($file | path relative-to $scope | path split) | any {|part| $part in $GENERATED_DIRECTORY_NAMES })
    }
    | where {|file| not ($nested | any {|directory| $file | str starts-with $'($directory)/' }) }
    | each {|file| $file | path relative-to $scope }
}

def exclusion-arguments [flag: string]: nothing -> list<string> {
    quality-gate-exclude-patterns
    | each {|pattern| [$flag $pattern] }
    | flatten
}

# Directories from `start` up to the repository root, nearest first. A member of
# an npm, pnpm or uv workspace has no lockfile, `.node-version` or `node_modules`
# of its own, so these are looked up towards the root.
def ancestor-directories [start: path]: nothing -> list<path> {
    let root = quality-gate-root
    mut current = $start | path expand
    mut directories = [$current]
    while $current != $root and ($current | str starts-with $'($root)/') {
        $current = ($current | path dirname)
        $directories = ($directories | append $current)
    }
    $directories
}

def find-up [start: path, names: list<string>]: nothing -> oneof<path, nothing> {
    for directory in (ancestor-directories $start) {
        for name in $names {
            let candidate = $directory | path join $name
            if ($candidate | path exists) {
                return $candidate
            }
        }
    }
    null
}

def quality-gate-cache-dir []: nothing -> path {
    let base = $env.XDG_CACHE_HOME? | default ($env.HOME? | default '/tmp' | path join .cache)
    $base | path join quality-gate
}

# uv and basedpyright use an environment that belongs to the Quality Gate. It
# lives outside the repository, so `uv sync` never prunes the developer's own
# `.venv` and nothing is left in the working tree.
def python-venv-dir []: nothing -> path {
    let key = $env.PWD | path expand | hash sha256 | str substring 0..15
    (quality-gate-cache-dir) | path join venvs $key
}

def sync-python []: nothing -> nothing {
    if not ('pyproject.toml' | path exists) {
        error make {msg: 'finding: Python typecheck/tests require pyproject.toml managed by uv; setup.py-only projects are unsupported for dependency-aware checks.'}
    }
    let lockfile = find-up $env.PWD [uv.lock]
    if $lockfile == null {
        error make {msg: 'finding: Python typecheck/tests require uv.lock. Run `uv lock` and commit the lockfile.'}
    }

    let venv = python-venv-dir
    let marker = $venv | path join .quality-gate-uv-sync
    let pinned = if ('.python-version' | path exists) { open --raw .python-version } else { '' }
    let fingerprint = ([ (open --raw pyproject.toml) (open --raw $lockfile) $pinned ] | str join (char nul) | hash sha256 | str trim)
    let current = if ($marker | path exists) { open --raw $marker | str trim } else { '' }
    if $current == $fingerprint {
        log info 'uv dependencies are up to date; skipping uv sync.'
    } else {
        with-env {UV_PROJECT_ENVIRONMENT: $venv} {
            run-check 'uv sync' uv [sync --locked --all-groups] --finding-codes []
        }
        mkdir $venv
        $fingerprint | save --force $marker
    }
}

def python-project []: nothing -> bool {
    if not (has-project-file $PYTHON_PROJECT_FILES) {
        skip python
        false
    } else {
        true
    }
}

def warn-unsupported-python-manager [directory: path] {
    if ('setup.py' | path exists) and not ('pyproject.toml' | path exists) {
        log warning $'Python project ($directory) uses setup.py without pyproject.toml; dependency-aware Quality Gate checks require uv.'
    } else if ('pyproject.toml' | path exists) and ((open --raw pyproject.toml) | str contains '[tool.poetry]') {
        log warning $'Python project ($directory) declares Poetry; dependency-aware Quality Gate checks support uv.lock only.'
    }
}

def format-python [] {
    if not (python-project) { return }
    warn-local-quality-config ['ruff.toml' '.ruff.toml']

    let files = quality-gate-files [py pyi] --language python
    if ($files | is-empty) {
        log warning 'No Python source files remain after .quality-gate/exclude; skipping format.'
        return
    }
    let arguments = ([format --check --config $env.QUALITY_GATE_RUFF_CONFIG] ++ $files)
    let result = capture ruff $arguments
    if $result.exit_code == 0 {
        print 'ruff format: all files are correctly formatted.'
        return
    }

    if ($result.stdout | is-not-empty) { print ($result.stdout | str trim) }
    if ($result.stderr | is-not-empty) { print -e ($result.stderr | str trim) }
    if $result.exit_code == 1 {
        let diff = capture ruff ([format --diff --config $env.QUALITY_GATE_RUFF_CONFIG] ++ $files)
        if ($diff.stdout | is-not-empty) { print ($diff.stdout | str trim) }
    }
    format-check-failure ruff $result 'ruff format found formatting differences; run `qg format py`'
}

def lint-python [] {
    if not (python-project) { return }
    warn-local-quality-config ['ruff.toml' '.ruff.toml']
    let files = quality-gate-files [py pyi] --language python
    if ($files | is-empty) {
        log warning 'No Python source files remain after .quality-gate/exclude; skipping lint.'
        return
    }
    run-check 'ruff check' ruff (
        [check --config $env.QUALITY_GATE_RUFF_CONFIG] ++ $files
    )
}

def lint-python-complexipy [] {
    if not (python-project) { return }
    let files = quality-gate-files [py pyi] --language python
    if ($files | is-empty) {
        log warning 'No Python source files remain after .quality-gate/exclude; skipping complexity.'
        return
    }
    if (
        ('.complexipy.toml' | path exists)
        or ('complexipy.toml' | path exists)
        or ((open --raw pyproject.toml | str contains '[tool.complexipy]'))
    ) {
        log warning 'Ignoring local complexipy configuration; the central Quality Gate policy is mandatory.'
    }
    let temporary = (mktemp --directory | str trim)
    try {
        [
            'paths = []'
            'max-complexity-allowed = 15'
            'ignore-complexity = false'
            'no-ignore = false'
        ] | str join (char nl) | $in + (char nl) | save --force ($temporary | path join complexipy.toml)
        let absolute = $files
            | each {|file| (project | path join $file) | path expand | into string }
        cd $temporary
        run-check 'complexipy' complexipy ($absolute ++ [--max-complexity-allowed '15'])
    } finally {
        cd (project)
        rm --recursive --force $temporary
    }
}

def typecheck-python-basedpyright [] {
    if not (python-project) { return }
    sync-python
    warn-local-quality-config ['pyrightconfig.json']
    let config = (python-quality-config)
    let arguments = [--project $config]
    try {
        run-check 'basedpyright' basedpyright ($arguments ++ [.])
    } finally {
        rm $config
    }
}

def python-quality-config []: nothing -> path {
    let central = open $env.QUALITY_GATE_PYRIGHT_CONFIG
    let scope = project
    let root = quality-gate-root
    let files = git-repository-files $scope
    let excludes = git-excluded-relative (
        $files | each {|file| $file | path relative-to $root }
    ) | each {|file| $root | path join $file | path expand }
        | each {|file| $file | path relative-to $scope }
    let config = project | path join '.quality-gate-pyrightconfig.json'
    rm --force $config
    $central
    | upsert venvPath (python-venv-dir | path dirname)
    | upsert venv (python-venv-dir | path basename)
    | upsert exclude (($PYRIGHT_DEFAULT_EXCLUDES ++ $excludes) | uniq)
    | to json
    | save --force $config
    $config
}

def ast-grep-config [rules: path, language: string]: nothing -> path {
    let config = (mktemp | str trim)
    let content = if $language == typescript {
        [
            'ruleDirs:'
            $'  - ($rules)'
            'languageGlobs:'
            '  typescript:'
            '    - "*.ts"'
            '    - "*.tsx"'
            '    - "*.mts"'
            '    - "*.cts"'
            '  html:'
            '    - "*.vue"'
            'languageInjections:'
            '  - hostLanguage: html'
            '    rule:'
            '      pattern: <script>$$$CONTENT</script>'
            '    injected: [javascript, typescript]'
            '  - hostLanguage: html'
            '    rule:'
            '      pattern: <script setup>$$$CONTENT</script>'
            '    injected: [javascript, typescript]'
            '  - hostLanguage: html'
            '    rule:'
            '      pattern: <script lang="$LANG">$$$CONTENT</script>'
            '    injected: [javascript, typescript]'
            '  - hostLanguage: html'
            '    rule:'
            '      pattern: <script setup lang="$LANG">$$$CONTENT</script>'
            '    injected: [javascript, typescript]'
            '  - hostLanguage: html'
            '    rule:'
            '      pattern: <script lang="$LANG" setup>$$$CONTENT</script>'
            '    injected: [javascript, typescript]'
        ] | str join (char nl) | $in + (char nl)
    } else {
        (['ruleDirs:' $'  - ($rules)'])
        | str join (char nl)
        | $in + (char nl)
    }
    $content | save --force $config
    $config
}

def ast-grep-exclusion-arguments []: nothing -> list<string> {
    let root = quality-gate-root
    let scope = project
    let files = git-repository-files $scope
    let excluded = git-excluded-relative (
        $files | each {|file| $file | path relative-to $root }
    )
    $excluded
    | each {|file|
        let absolute = $root | path join $file | path expand
        let relative = $absolute | path relative-to $scope
        ['--globs' $'!($relative)']
    }
    | flatten
}

def local-ast-grep-config []: nothing -> oneof<record, nothing> {
    if ('.quality-gate/sgconfig.yaml' | path exists) {
        { path: '.quality-gate/sgconfig.yaml', temporary: false }
    } else if ('.quality-gate/rules' | path type) == dir {
        let config = (mktemp | str trim)
        ['ruleDirs:' '  - .quality-gate/rules']
        | str join (char nl)
        | $in + (char nl)
        | save --force $config
        { path: $config, temporary: true }
    } else {
        null
    }
}

def lint-strlint [language: string, rules: path] {
    let central = ast-grep-config $rules $language
    try {
        run-check $'($language) organizational ast-grep rules' ast-grep (
            [scan --config $central .] ++ (ast-grep-exclusion-arguments)
        )
    } finally {
        rm $central
    }

    let local = local-ast-grep-config
    if $local == null {
        log info 'No repository-local ast-grep rules found; skipping.'
    } else {
        try {
            run-check $'($language) repository ast-grep rules' ast-grep (
                [scan --config $local.path .] ++ (ast-grep-exclusion-arguments)
            )
        } finally {
            if $local.temporary {
                rm $local.path
            }
        }
    }
}

def go-project []: nothing -> bool {
    if not ('go.mod' | path exists) {
        skip go
        false
    } else {
        true
    }
}

def format-go-gofumpt [] {
    if not (go-project) { return }
    let files = quality-gate-files [go] --language go
    if ($files | is-empty) {
        log warning 'No Go source files remain after .quality-gate/exclude; skipping format.'
        return
    }
    let result = capture gofumpt ([-l] ++ $files)
    if $result.exit_code != 0 {
        error make {msg: 'engine: gofumpt could not inspect the project'}
    }
    if ($result.stdout | str trim | is-empty) {
        print 'gofumpt: all files are correctly formatted.'
    } else {
        print ($result.stdout | str trim)
        let diff = capture gofumpt ([-d] ++ $files)
        if ($diff.stdout | is-not-empty) { print ($diff.stdout | str trim) }
        error make {msg: 'finding: gofumpt found unformatted files; run `gofumpt -w .`'}
    }
}

def format-go-goimports [] {
    if not (go-project) { return }
    let files = quality-gate-files [go] --language go
    if ($files | is-empty) {
        log warning 'No Go source files remain after .quality-gate/exclude; skipping imports format.'
        return
    }
    let result = capture goimports ([-l] ++ $files)
    if $result.exit_code != 0 {
        error make {msg: 'engine: goimports could not inspect the project'}
    }
    if ($result.stdout | str trim | is-empty) {
        print 'goimports: all import blocks are correctly organised.'
    } else {
        print ($result.stdout | str trim)
        let diff = capture goimports ([-d] ++ $files)
        if ($diff.stdout | is-not-empty) { print ($diff.stdout | str trim) }
        error make {msg: 'finding: goimports found unorganised imports; run `goimports -w .`'}
    }
}

def lint-go-golangci [] {
    if not (go-project) { return }
    warn-local-quality-config ['.golangci.yml' '.golangci.yaml' '.golangci.toml' '.golangci.json']
    let config = (go-quality-config)
    try {
        run-check 'golangci-lint' golangci-lint [run --allow-parallel-runners --config $config]
    } finally {
        rm $config
    }
}

def regex-escape [value: string]: nothing -> string {
    $value | str replace --all --regex '([\\.+*?()|\[\]{}^$])' '\$1'
}

def go-quality-config []: nothing -> path {
    let central = open $env.QUALITY_GATE_GO_CONFIG
    let scope = project
    let root = quality-gate-root
    let files = git-repository-files $scope
    let paths = git-excluded-relative (
        $files | each {|file| $file | path relative-to $root }
    ) | each {|path| $root | path join $path | path expand | path relative-to $scope }
        | each {|path| $'^(regex-escape $path)$' }
    let exclusions = $central.linters.exclusions | upsert paths (
        (($central.linters.exclusions.paths? | default []) ++ $paths) | uniq
    )
    let config = mktemp --suffix .yml | str trim
    $central
    | upsert linters ($central.linters | upsert exclusions $exclusions)
    | to yaml
    | save --force $config
    $config
}

def lint-go-vet [] {
    if not (go-project) { return }
    let packages = go-packages
    if ($packages | is-empty) {
        log warning 'All Go packages are excluded by .quality-gate/exclude; skipping go vet.'
        return
    }
    run-check 'go vet' go ([vet] ++ $packages)
}

def typecheck-go [] {
    if not (go-project) { return }
    let packages = go-packages
    if ($packages | is-empty) {
        log warning 'All Go packages are excluded by .quality-gate/exclude; skipping go build.'
        return
    }
    run-check 'go build' go ([build -o /dev/null] ++ $packages)
}

def go-packages []: nothing -> list<string> {
    if (quality-gate-exclude-patterns | is-empty) {
        return ['./...']
    }
    let result = capture go [list -f '{{.ImportPath}} {{.Dir}}' ./...]
    if $result.exit_code != 0 {
        error make {msg: 'engine: go list could not inspect the project'}
    }
    $result.stdout
    | lines
    | where {|line| ($line | str trim | is-not-empty) }
    | each {|line|
        let package = $line | split row ' ' | first
        { package: $package, directory: ($line | str substring (($package | str length) + 1)..) }
    }
    | where {|row| not (quality-gate-path-excluded $row.directory) }
    | get package
}

def node-lockfile [start: path = .]: nothing -> oneof<path, nothing> {
    find-up ($start | path expand) [pnpm-lock.yaml package-lock.json]
}

def node-manager []: nothing -> string {
    let lockfile = node-lockfile
    if $lockfile == null {
        error make {msg: 'finding: No lockfile found. Commit package-lock.json (npm) or pnpm-lock.yaml (pnpm), at the project or at its workspace root.'}
    }
    if ($lockfile | path basename) == 'pnpm-lock.yaml' {
        let package = open ($lockfile | path dirname | path join package.json)
        let declaration = ($package.packageManager? | default '')
        if (($declaration | describe) != string) or not ($declaration =~ '^pnpm@[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$') {
            error make {msg: 'finding: pnpm-lock.yaml requires package.json packageManager: pnpm@<version>.'}
        }
        'pnpm'
    } else {
        'npm'
    }
}

def node-project []: nothing -> bool {
    if not (('package.json' | path exists) and ('tsconfig.json' | path exists)) {
        skip typescript
        false
    } else {
        true
    }
}

def install-node-dependencies []: nothing -> nothing {
    let manager = node-manager
    let lockfile = node-lockfile
    let lock_directory = $lockfile | path dirname
    let declared_version = find-up $env.PWD [.node-version]
    let fingerprint = [
        (open --raw ($lock_directory | path join package.json))
        (open --raw $lockfile)
        (if $declared_version != null { open --raw $declared_version } else { $env.QUALITY_GATE_NODE_VERSION? | default '' })
    ] | str join (char nul) | hash sha256 | str trim
    let marker = $lock_directory | path join node_modules .quality-gate-dependencies
    let current = if ($marker | path exists) { open --raw $marker | str trim } else { '' }
    if $current == $fingerprint {
        log info 'Node dependencies are up to date; skipping install.'
        return
    }
    let project_directory = $env.PWD
    cd $lock_directory
    try {
        if $manager == npm {
            run-check 'npm ci' npm [ci] --finding-codes []
        } else {
            run-check 'pnpm install' pnpm [install --frozen-lockfile] --finding-codes []
        }
        mkdir ($lock_directory | path join node_modules)
        $fingerprint | save --force $marker
    } finally {
        cd $project_directory
    }
}

def declared-node-major []: nothing -> string {
    let configured = ($env.QUALITY_GATE_NODE_VERSION? | default '')
    let version_file = find-up $env.PWD [.node-version]
    let declared = if $version_file != null {
        open --raw $version_file | str trim
    } else {
        $configured | str trim
    }
    if ($declared | is-empty) {
        error make {msg: 'finding: Missing .node-version for TypeScript typecheck. Add the Node.js major version used by the project.'}
    }
    $declared | str replace --regex '^v' '' | split row '.' | first
}

# The app exports one bin directory per bundled Node.js major
# (QUALITY_GATE_NODE_<major>_BIN); each project selects its own.
def with-node-runtime [body: closure] {
    let major = declared-node-major
    let bin = $env | get --optional $'QUALITY_GATE_NODE_($major)_BIN'
    if $bin == null {
        validate-node-version
        do $body
    } else {
        with-env {PATH: ($env.PATH | prepend $bin)} {
            validate-node-version
            do $body
        }
    }
}

def local-node-bin [name: string]: nothing -> string {
    let found = ancestor-directories $env.PWD
        | each {|directory| $directory | path join node_modules .bin $name }
        | where {|binary| $binary | path exists }
        | get --optional 0
    if $found == null {
        error make {msg: $'finding: ($name) is not installed in the project. Add it to devDependencies and commit the lockfile.'}
    }
    $found
}

def validate-node-version []: nothing -> nothing {
    let expected = declared-node-major
    let actual_result = capture node [--version]
    if $actual_result.exit_code != 0 {
        error make {msg: 'The Quality Gate could not determine the Node.js runtime version.'}
    }
    let actual = $actual_result.stdout | str trim | str replace --regex '^v' '' | split row '.' | first
    if $expected != $actual {
        error make {msg: $'Project declares Node.js major ($expected), but the Quality Gate runtime provides ($actual).'}
    }
}

def package-has-script [name: string]: nothing -> bool {
    let package = open package.json
    ($package.scripts? | default {} | get --optional $name | is-not-empty)
}

def package-contains [value: string]: nothing -> bool {
    open --raw package.json | str contains $value
}

def package-has-dependency [name: string]: nothing -> bool {
    let package = open package.json
    [
        ($package.dependencies? | default {})
        ($package.devDependencies? | default {})
        ($package.optionalDependencies? | default {})
    ] | any {|dependencies|
        ($dependencies | get --optional $name | is-not-empty)
    }
}

def typescript-framework []: nothing -> string {
    if (package-has-dependency next) or (['next.config.js' 'next.config.mjs' 'next.config.cjs' 'next.config.ts' 'next.config.mts'] | any {|file| $file | path exists}) {
        'next'
    } else if (package-has-dependency nuxt) or (['nuxt.config.ts' 'nuxt.config.mts' 'nuxt.config.js' 'nuxt.config.mjs' 'nuxt.config.cjs'] | any {|file| $file | path exists}) {
        'nuxt'
    } else if (package-has-dependency vue) or (
        glob --no-dir '**/*.vue'
        | where {|file|
            let parts = $file | path split
            not ($parts | any {|part| $part in ['node_modules' '.git' 'dist' 'build' 'out'] })
        }
        | is-not-empty
    ) {
        'vue'
    } else {
        'none'
    }
}

def typescript-react-project []: nothing -> bool {
    (package-has-dependency react) or (package-has-dependency 'react-dom')
}

def format-typescript [] {
    if not (node-project) { return }
    warn-local-quality-config ['.oxfmtrc.json' '.oxfmtrc.jsonc' 'oxfmt.config.js' 'oxfmt.config.mjs' 'oxfmt.config.ts' 'oxfmt.config.mts']
    let files = quality-gate-files [ts tsx mts cts vue] --language typescript
    if ($files | is-empty) {
        log warning 'No TypeScript source files remain after .quality-gate/exclude; skipping format.'
        return
    }
    let result = capture oxfmt (
        [--config $env.QUALITY_GATE_OXFMT_CONFIG --list-different] ++ $files
    )
    if $result.exit_code == 0 {
        print 'oxfmt: all files are correctly formatted.'
    } else {
        if ($result.stdout | is-not-empty) { print ($result.stdout | str trim) }
        if ($result.stderr | is-not-empty) { print -e ($result.stderr | str trim) }
        format-check-failure oxfmt $result 'oxfmt found formatting differences; run `qg format ts`'
    }
}

def lint-typescript-oxlint [] {
    if not (node-project) { return }
    warn-local-quality-config ['.oxlintrc.json' '.oxlintrc.yaml' '.oxlintrc.yml' 'oxlint.config.js' 'oxlint.config.mjs' 'oxlint.config.ts']
    let source_files = quality-gate-files [ts tsx mts cts vue] --language typescript
    if ($source_files | is-empty) {
        log warning 'No TypeScript source files remain after .quality-gate/exclude; skipping lint.'
        return
    }
    let paths = ([--config $env.QUALITY_GATE_OXLINT_CONFIG] ++ $source_files)
    let framework = typescript-framework
    let arguments = if $framework == next {
        [--react-plugin --jsx-a11y-plugin --nextjs-plugin --ignore-pattern '.next/**' --ignore-pattern 'out/**'] ++ $paths
    } else if (typescript-react-project) {
        [--react-plugin --jsx-a11y-plugin] ++ $paths
    } else {
        $paths
    }
    run-check 'oxlint' oxlint $arguments --engine-markers ['Failed to parse oxlint configuration']
}

def typecheck-typescript [] {
    if not (node-project) { return }
    with-node-runtime { typescript-typecheck }
}

def typescript-typecheck [] {
    install-node-dependencies
    let manager = node-manager
    let framework = typescript-framework
    let checker = if $framework in [vue nuxt] { 'vue-tsc' } else { 'tsc' }
    let binary = local-node-bin $checker
    # Nuxt generates .nuxt/tsconfig.json, which the project config extends, so it
    # must exist before any config is expanded.
    if $framework == nuxt {
        if $manager == npm {
            run-check 'nuxt prepare' npm [exec --no -- nuxt prepare]
        } else {
            run-check 'nuxt prepare' pnpm [exec nuxt prepare]
        }
    }
    let configs = (typescript-quality-configs $binary)
    try {
        for config in $configs {
            run-check $checker $binary [--noEmit --project $config] --finding-codes [1 2]
        }
    } finally {
        for config in $configs {
            rm $config
        }
    }
}

# `vue-tsc --showConfig` lists the `.vue` files and `tsc --showConfig` does not,
# so the expansion is done with the compiler the project is checked with.
def typescript-show-config [config: path, binary: string]: nothing -> record {
    let result = capture $binary [--showConfig --project $config]
    if $result.exit_code != 0 {
        error make {msg: $'finding: Could not expand TypeScript config ($config): ($result.stderr | str trim)($result.stdout | str trim)'}
    }
    try {
        $result.stdout | from json
    } catch {|error|
        error make {msg: $'finding: Could not parse TypeScript config ($config): ($error.msg)'}
    }
}

# The files of a project come from its own `files` and `include`, but a local
# `exclude` must not take files out of the Quality Gate. The config is expanded
# once more through a derived config, kept beside the original so relative paths
# resolve the same way, that replaces `exclude` by the compiler defaults.
def typescript-effective-config [config: path, binary: string]: nothing -> record {
    let original = typescript-show-config $config $binary
    let out_directory = $original.compilerOptions?.outDir?
    let excludes = ['**/node_modules' '**/bower_components' '**/jspm_packages']
        | append (if $out_directory == null { [] } else { [$out_directory] })
    let widened = (mktemp --tmpdir-path ($config | path dirname) '.quality-gate-tsconfig.XXXXXX.json' | str trim)
    try {
        {extends: $'./($config | path basename)', exclude: $excludes} | to json | save --force $widened
        let effective = typescript-show-config $widened $binary
        rm --force $widened
        $effective | upsert references ($original.references? | default [])
    } catch {|error|
        rm --force $widened
        error make $error
    }
}

def typescript-project-file [base: path, file: string]: nothing -> path {
    if ($file | str starts-with '/') {
        $file | path expand
    } else {
        $base | path join $file | path expand
    }
}

def typescript-reference-sources [config: path, binary: string]: nothing -> list<record> {
    let effective = typescript-effective-config $config $binary
    let source = {
        base: ($config | path dirname)
        config: $config
        effective: $effective
    }
    let references = ($effective.references? | default [])
        | each {|reference|
            typescript-project-file ($config | path dirname) $reference.path
        }
    [$source] ++ ($references | each {|reference| typescript-reference-sources $reference $binary } | flatten)
}

def typescript-quality-configs [binary: string]: nothing -> list<path> {
    let central = (open $env.QUALITY_GATE_TYPESCRIPT_CONFIG)
    let root_config = $env.PWD | path join 'tsconfig.json' | path expand
    let root = (typescript-effective-config $root_config $binary)
    let references = ($root.references? | default [])
    let root_source = {
        base: ($root_config | path dirname)
        config: $root_config
        effective: $root
    }
    let referenced_sources = $references
        | each {|reference|
            typescript-reference-sources (
                typescript-project-file ($root_config | path dirname) $reference.path
            ) $binary
        }
        | flatten
    let sources = if ($references | is-empty) {
        [$root_source]
    } else if (($root.files? | default [] | is-not-empty) or ($root.include? | default [] | is-not-empty)) {
        [$root_source] ++ $referenced_sources
    } else {
        $referenced_sources
    }

    $sources | each {|source|
        let effective = $source.effective
        let options = ($effective.compilerOptions? | default {}) | merge $central.compilerOptions
        let declared = ($effective.files? | default [])
            | each {|file| typescript-project-file $source.base $file }
        let files = $declared | where {|file| not (typescript-file-excluded $file) }
        if ($declared | is-not-empty) and ($files | is-empty) {
            null
        } else {
            let include = if ($files | is-empty) {
                ($effective.include? | default [])
                | each {|pattern| typescript-project-file $source.base $pattern }
            } else {
                []
            }
            # Keep the generated config beside the original project config. TypeScript
            # resolves relative compiler options (for example baseUrl, paths and
            # typeRoots) relative to the config file, not relative to the cwd.
            let config = (mktemp --tmpdir-path $source.base '.quality-gate-tsconfig.XXXXXX.json' | str trim)
            {
                compilerOptions: $options
                files: $files
                include: $include
                exclude: []
            } | to json | save --force $config
            $config
        }
    } | compact
}

# Files listed by the expanded tsconfig are checked against .quality-gate/exclude
# so tsc follows the same exclusions as every other tool.
def typescript-file-excluded [file: path]: nothing -> bool {
    let root = quality-gate-root
    let absolute = $file | path expand
    if not ($absolute | str starts-with $'($root)/') {
        return false
    }
    (git-excluded-relative [($absolute | path relative-to $root)] | is-not-empty)
}

def test-python [] {
    require-local-tests python
    sync-python
    with-env {UV_PROJECT_ENVIRONMENT: (python-venv-dir)} {
        run-check 'uv pytest' uv [run --locked pytest] --any-failure-is-finding
    }
}

def test-go [] {
    require-local-tests go
    run-check 'go test' go [test ./...] --any-failure-is-finding
}

def test-typescript [] {
    require-local-tests typescript
    if not (package-has-script test) {
        error make {msg: 'finding: TypeScript projects must define scripts.test in package.json.'}
    }
    with-node-runtime {
        install-node-dependencies
        let manager = node-manager
        if $manager == npm {
            run-check 'npm test' npm [run test] --any-failure-is-finding
        } else {
            run-check 'pnpm test' pnpm [run test] --any-failure-is-finding
        }
    }
}

def checks-for-category [category: string, language: string]: nothing -> list<list<string>> {
    match [$category $language] {
        [format python] => [[format python ruff]]
        [format go] => [[format go gofumpt] [format go goimports]]
        [format typescript] => [[format typescript oxfmt]]
        [lint python] => [
            [lint python ruff]
            [lint python complexipy]
        ]
        [lint go] => [
            [lint go golangci]
            [lint go vet]
        ]
        [lint typescript] => [
            [lint typescript oxlint]
        ]
        [strlint python] => [[lint python strlint]]
        [strlint go] => [[lint go strlint]]
        [strlint typescript] => [[lint typescript strlint]]
        [typecheck python] => [[typecheck python basedpyright]]
        [typecheck go] => [[typecheck go build]]
        [typecheck typescript] => [[typecheck typescript tsc]]
        [test python] => [[test python pytest]]
        [test go] => [[test go test]]
        [test typescript] => [[test typescript test]]
        _ => []
    }
}

def checks-for-language [language: string]: nothing -> list<list<string>> {
    match $language {
        'python' => [
            [format python ruff]
            [lint python ruff]
            [lint python complexipy]
            [lint python strlint]
            [typecheck python basedpyright]
        ]
        'go' => [
            [format go gofumpt]
            [format go goimports]
            [lint go golangci]
            [lint go strlint]
            [lint go vet]
            [typecheck go build]
        ]
        'typescript' => [
            [format typescript oxfmt]
            [lint typescript oxlint]
            [lint typescript strlint]
            [typecheck typescript tsc]
        ]
        _ => []
    }
}

def normalize-language [language: string]: nothing -> string {
    match $language {
        'py' | 'python' => 'python'
        'go' => 'go'
        'ts' | 'typescript' => 'typescript'
        _ => (error make {msg: $'Unknown language alias: ($language)'})
    }
}

def run-language-checks [language: string, commands: list<list<string>>]: nothing -> record {
    let scope = (project)
    cd $scope
    let directories = project-directories-or-error
    mut results = []

    for directory in $directories {
        if $language not-in (project-languages $directory) {
            continue
        }
        for command in $commands {
            $results = ($results | append (run-project-check $directory $language $command.0 $command.2))
        }
    }

    {
        scope: $scope
        directories: $directories
        results: $results
    }
}

def run-language-ci [language: string] {
    let normalized = normalize-language $language
    let scope = (project)
    cd $scope
    let directories = project-directories
    if ($directories | is-empty) {
        print-console-summary $'($normalized) hook checks' $scope []
        return
    }
    mut results = []

    for category in [format lint strlint typecheck] {
        for directory in $directories {
            if $normalized not-in (project-languages $directory) {
                continue
            }
            for command in (checks-for-category $category $normalized) {
                $results = ($results | append (run-project-check $directory $normalized $command.0 $command.2))
            }
        }
    }

    let cgo_notice = go-cgo-notice $scope $results
    print-console-summary $'($normalized) hook checks' $scope $results $cgo_notice
    let failures = $results | where status == failure
    if not ($failures | is-empty) {
        let failure_count = ($failures | length)
        let result_count = ($results | length)
        if not (report-only) {
            error make {msg: $"($normalized) hook checks failed: ($failure_count) of ($result_count) checks failed."}
        }
        log warning $'REPORT-ONLY: ($normalized) hook checks found ($failure_count) of ($result_count) failed checks.'
    }
}

def run-fix-check [name: string, command: string, arguments: list<string>] {
    log info $'Running ($name)...'
    let result = capture $command $arguments
    if ($result.stdout | is-not-empty) {
        print ($result.stdout | str trim)
    }
    if ($result.stderr | is-not-empty) {
        print -e ($result.stderr | str trim)
    }
    if $result.exit_code != 0 {
        log warning $'($name) returned exit code ($result.exit_code); continuing with the remaining fixes.'
    }
}

def fix-language [language: string] {
    let normalized = normalize-language $language
    let scope = (project)
    let root = quality-gate-root
    cd $scope
    for directory in (project-directories) {
        if $normalized not-in (project-languages $directory) {
            continue
        }
        # Each project is fixed with the scope it is checked with, so the file
        # lists, exclusions and nested projects are those of that project.
        let environment = {QUALITY_GATE_PROJECT_DIR: $directory, QUALITY_GATE_ROOT: $root}
        let environment = if $normalized == go { $environment | insert CGO_ENABLED '0' } else { $environment }
        with-env $environment {
            cd $directory
            match $normalized {
                python => {
                    let files = quality-gate-files [py pyi] --language python
                    if ($files | is-empty) {
                        log warning 'No Python source files remain after .quality-gate/exclude; skipping fixes.'
                    } else {
                        run-fix-check 'ruff format' ruff (
                            [format --config $env.QUALITY_GATE_RUFF_CONFIG] ++ $files
                        )
                        run-fix-check 'ruff check --fix' ruff (
                            [check --config $env.QUALITY_GATE_RUFF_CONFIG --fix] ++ $files
                        )
                    }
                }
                go => {
                    let files = quality-gate-files [go] --language go
                    if ($files | is-empty) {
                        log warning 'No Go source files remain after .quality-gate/exclude; skipping fixes.'
                    } else {
                        run-fix-check 'gofumpt' gofumpt ([-w] ++ $files)
                        run-fix-check 'goimports' goimports ([-w] ++ $files)
                    }
                }
                typescript => {
                    let files = quality-gate-files [ts tsx mts cts vue] --language typescript
                    if ($files | is-empty) {
                        log warning 'No TypeScript source files remain after .quality-gate/exclude; skipping fixes.'
                    } else {
                        run-fix-check 'oxfmt' oxfmt (
                            [--config $env.QUALITY_GATE_OXFMT_CONFIG --write] ++ $files
                        )
                    }
                }
            }
        }
        cd $scope
    }
}

def report-language-checks [title: string, language: string, commands: list<list<string>>] {
    let run = run-language-checks $language $commands
    write-reports $title $run.scope $run.results
    let failures = $run.results | where status == failure

    if ($run.results | is-empty) {
        log warning $'No ($language) checks apply to the discovered projects.'
    }
    if not ($failures | is-empty) {
        let failure_count = ($failures | length)
        let result_count = ($run.results | length)
        if not (report-only) {
            error make {msg: $"($title) failed: ($failure_count) of ($result_count) checks failed."}
        }
        log warning $'REPORT-ONLY: ($title) found ($failure_count) of ($result_count) failed checks.'
    }
}

def run-language-category [category: string, language: string] {
    if $category not-in [format lint strlint typecheck test] {
        error make {msg: $'Unknown quality-gate category: ($category)'}
    }
    let normalized = normalize-language $language
    report-language-checks ($'($normalized) ($category)') $normalized (checks-for-category $category $normalized)
}

def check-fix [directory: path, verb: string, language: string, check: string]: nothing -> string {
    match [$verb $language $check] {
        [format python ruff] => 'qg fix python'
        [lint python ruff] => 'qg fix python  # applies the safe fixes; fix the remaining findings by hand'
        [lint python complexipy] => 'Reduce the cognitive complexity of the reported functions (limit 15), then run `qg lint python`'
        [typecheck python basedpyright] => 'Fix the reported type errors, then run `qg typecheck python`'
        [lint python strlint] => 'Fix the reported structural findings, then run `qg strlint python`'
        [format go gofumpt] => 'qg fix go'
        [format go goimports] => 'qg fix go'
        [lint go golangci] => 'Fix the reported findings, then run `qg lint go`'
        [lint go strlint] => 'Fix the reported structural findings, then run `qg strlint go`'
        [lint go vet] => 'go vet ./...'
        [typecheck go build] => 'go build ./...'
        [format typescript oxfmt] => 'qg fix typescript'
        [lint typescript oxlint] => 'Fix the reported findings, then run `qg lint typescript`'
        [lint typescript strlint] => 'Fix the reported structural findings, then run `qg strlint typescript`'
        [typecheck typescript tsc] => 'Fix the reported type errors, then run `qg typecheck typescript`'
        [test python pytest] => 'uv run pytest'
        [test go test] => 'go test ./...'
        [test typescript test] => (if ((node-lockfile $directory | default '' | path basename) == 'pnpm-lock.yaml') { 'pnpm test' } else { 'npm test' })
        _ => 'See the quality-gate task output above.'
    }
}

def run-project-check [directory: string, language: string, verb: string, check: string]: nothing -> record {
    let scope = quality-gate-root
    let output_file = (mktemp | str trim)
    let result = try {
        with-env {
            QUALITY_GATE_PROJECT_DIR: $directory
            QUALITY_GATE_ROOT: $scope
            QUALITY_GATE_CHECK_OUTPUT: $output_file
        } {
            run-command $verb $language $check
        }
        { status: 'success', category: 'none', error: '' }
    } catch {|err|
        let message = ($err.msg? | default ($err | to text))
        let category = if ($message | str starts-with 'finding:') {
            'finding'
        } else if ($message | str starts-with 'engine:') {
            'engine'
        } else {
            'engine'
        }
        {
            status: 'failure'
            category: $category
            error: $message
        }
    }
    let diagnostics = if ($output_file | path exists) { open --raw $output_file | str trim } else { '' }
    rm $output_file
    let error = if $result.status == 'failure' and ($diagnostics | is-not-empty) {
        $'($result.error)

Diagnostics:
($diagnostics)'
    } else {
        $result.error
    }

    {
        project: $directory
        language: $language
        check: $'($verb):($language):($check)'
        status: $result.status
        category: $result.category
        error: $error
        fix: (if $result.category == engine {
            'Check the execution environment and the diagnostic above, then rerun this check.'
        } else {
            check-fix $directory $verb $language $check
        })
    }
}

def xml-escape [value: string]: nothing -> string {
    strip-terminal-codes $value
    | str replace --all '&' '&amp;'
    | str replace --all '<' '&lt;'
    | str replace --all '>' '&gt;'
    | str replace --all '"' '&quot;'
    | str replace --all "'" '&apos;'
}

def xml-cdata [value: string]: nothing -> string {
    strip-terminal-codes $value | str replace --all ']]>' ']]]]><![CDATA[>'
}

def result-project [result: record, scope: string]: nothing -> string {
    let relative = ($result.project | path relative-to $scope)
    if ($relative | is-empty) or $relative == '.' { '.' } else { $relative }
}

# `go list` loads metadata without compiling. Comparing both settings also
# finds packages that disappear entirely when cgo is disabled. Only project
# files are reported; dependency files and paths explicitly excluded by the
# consumer are outside this list.
def go-list-metadata [directory: path, cgo: string]: nothing -> record {
    let result = try {
        with-env {CGO_ENABLED: $cgo} {
            cd $directory
            capture go [list -e '-json=Dir,GoFiles,CgoFiles,TestGoFiles,XTestGoFiles,Error,Incomplete' ./...]
        }
    } catch { return {ok: false, files: []} }
    if $result.exit_code != 0 { return {ok: false, files: []} }
    let text = $result.stdout | str trim
    # With cgo disabled all packages may legitimately disappear. An empty
    # cgo-enabled result cannot establish whether the inspection succeeded.
    if ($text | is-empty) { return {ok: ($cgo == '0'), files: []} }
    let json = $text | str replace --all --regex '(?m)^}\r?\n\{' "},\n{"
    let packages = try { $'[($json)]' | from json } catch { return {ok: false, files: []} }
    let files = try {
        $packages | each {|pkg|
            let directory = $pkg.Dir? | default ''
            if ($directory | is-empty) {
                []
            } else {
                let names = ($pkg.GoFiles? | default []) ++ ($pkg.CgoFiles? | default []) ++ ($pkg.TestGoFiles? | default []) ++ ($pkg.XTestGoFiles? | default [])
                $names | each {|name| $directory | path join $name | path expand }
            }
        } | flatten | uniq
    } catch { return {ok: false, files: []} }
    let incomplete = $packages | any {|pkg| ($pkg.Dir? | default '' | is-empty) or ($pkg.Error? | default null) != null or ($pkg.Incomplete? | default false) }
    {ok: (not $incomplete), files: $files}
}

def go-cgo-notice [scope: path, results: list<record>]: nothing -> string {
    let projects = $results | where language == go
        | where {|row| $row.check in ['lint:go:golangci' 'lint:go:vet' 'typecheck:go:build' 'test:go:test'] }
        | get project | uniq
    if ($projects | is-empty) { return '' }
    let checks = $projects | each {|directory|
        let project = $directory | path relative-to $scope
        try {
            let enabled = go-list-metadata $directory '1'
            let disabled = go-list-metadata $directory '0'
            let project_files = with-env {QUALITY_GATE_PROJECT_DIR: $directory, QUALITY_GATE_ROOT: $scope} {
                quality-gate-files [go] --language go | each {|file| $directory | path join $file | path expand }
            }
            let omitted = $enabled.files | where {|file|
                $file not-in $disabled.files and $file in $project_files
            } | each {|file| $file | path relative-to $scope }
            {project: $project, ok: ($enabled.ok and $disabled.ok), files: $omitted}
        } catch { {project: $project, ok: false, files: []} }
    }
    let files = $checks | get files | flatten | uniq | sort
    let unavailable = $checks | where ok == false | get project | each {|p| if ($p | is-empty) { '.' } else { $p } }
    let lines = [
        'Go checks use CGO_ENABLED=0. The following project files selected only with cgo enabled are not compiled, vetted or tested (format and structural checks may still inspect them):'
        (if ($files | is-empty) { 'None detected.' } else { $files | each {|file| $'- ($file)' } | str join (char nl) })
        (if ($unavailable | is-empty) { '' } else { $'WARNING: cgo file detection was incomplete for: ($unavailable | str join ", "). Review these projects manually.' })
    ]
    $lines | where {|line| ($line | is-not-empty) } | str join (char nl)
}

def write-reports [title: string, scope: string, results: list<record>] {
    let cgo_notice = go-cgo-notice $scope $results
    print-console-summary $title $scope $results $cgo_notice
    write-summary $title $scope $results $cgo_notice
    write-junit $title $scope $results $cgo_notice
}

def cgo-markdown-notice [notice: string]: nothing -> string {
    let text = strip-terminal-codes $notice
    let runs = $text | parse --regex '(?<ticks>`{3,})' | get ticks
    let width = if ($runs | is-empty) { 3 } else { 1 + ($runs | each {|run| $run | str length } | math max) }
    let fence = '`' | fill --width $width --character '`'
    [$'($fence)text' $text $fence] | str join (char nl)
}

def print-console-summary [title: string, scope: string, results: list<record>, cgo_notice: string = ''] {
    let failures = $results | where status == failure
    let revision = $env.QUALITY_GATE_REVISION? | default 'unknown'
    print ''
    print $'Quality Gate — ($title)'
    print $'Scope: ($scope)'
    print $'Revision: ($revision)'
    print $'Mode: (if (report-only) { "report-only" } else { "blocking" })'
    let exclusions = quality-gate-exclude-patterns
    print $'Exclusions: (if ($exclusions | is-empty) { "none" } else { $exclusions | str join ", " })'
    if ($cgo_notice | is-not-empty) { print $cgo_notice }
    print ''
    print '| Project | Language | Check | Category | Outcome |'
    print '| --- | --- | --- | --- | --- |'
    for result in $results {
        let outcome = if $result.status == success { '✅ PASS' } else { '❌ FAIL' }
        print $'| `((result-project $result $scope))` | `($result.language)` | `($result.check)` | `($result.category)` | ($outcome) |'
    }
    print ''
    if ($failures | is-empty) {
        print $'Summary: all ($results | length) checks passed.'
    } else {
        print $'Summary: ($failures | length) of ($results | length) checks failed.'
        print ''
        print 'Failure details:'
        for failure in $failures {
            print $'### `($failure.project)` / ($failure.language) / ($failure.check)'
            print $'Category: `($failure.category)`'
            print $failure.error
            print $'How to fix: ($failure.fix)'
            print ''
        }
    }
    print ''
}

def write-summary [title: string, scope: string, results: list<record>, cgo_notice: string = ''] {
    let summary_file = ($env.QUALITY_GATE_SUMMARY_FILE? | default null)
    if $summary_file == null { return }

    let rows = $results | each {|result|
        let display_project = result-project $result $scope
        let outcome = if $result.status == 'success' { '✅ success' } else { '❌ failure' }
        $'| `($display_project)` | `($result.language)` | `($result.check)` | `($result.category)` | ($outcome) |'
    }
    let failures = $results | where status == failure
    let details = if ($failures | is-empty) {
        ['All discovered projects passed their quality checks.']
    } else {
        $failures | each {|failure|
            let display_project = result-project $failure $scope
            $'### `($display_project)` / ($failure.language) / `($failure.check)`

Category: `($failure.category)`
Failure:

```text
($failure.error)
```

How to fix it:

```text
($failure.fix)
```'
        }
    }
    let revision = $env.QUALITY_GATE_REVISION? | default 'unknown'
    let mode = if (report-only) { 'report-only' } else { 'blocking' }
    let content = [
        $'# Quality Gate — ($title)'
        ''
        $'Scope: `($scope)`'
        $'Revision: `($revision)`'
        $'Mode: `($mode)`'
        $'Exclusions: (if ((quality-gate-exclude-patterns) | is-empty) { "none" } else { (quality-gate-exclude-patterns | str join ", ") })'
        (if ($cgo_notice | is-empty) { '' } else { ['' '## Go cgo coverage' '' (cgo-markdown-notice $cgo_notice)] | str join (char nl) })
        (if (report-only) { '> REPORT-ONLY: failures are reported but do not block this execution.' } else { '' })
        ''
        '| Project | Language | Check | Category | Outcome |'
        '| --- | --- | --- | --- | --- |'
        ($rows | str join (char nl))
        ''
        '## Failure details'
        ''
        ($details | str join (char nl + char nl))
        ''
    ] | str join (char nl)
    $content | save --force $summary_file
}

def write-junit [title: string, scope: string, results: list<record>, cgo_notice: string = ''] {
    let junit_file = ($env.QUALITY_GATE_JUNIT_FILE? | default null)
    if $junit_file == null { return }

    let testcases = $results | each {|result|
        let project = result-project $result $scope
        let name = $'($project) / ($result.check)'
        let classname = $'($project).($result.language)'
        if $result.status == success {
            $'    <testcase classname="(xml-escape $classname)" name="(xml-escape $name)" />'
        } else {
            let categorized_error = $'Category: ($result.category)

($result.error)'
            let message = xml-escape $categorized_error
            let raw_message = xml-cdata $categorized_error
            let raw_fix = xml-cdata $result.fix
            $'    <testcase classname="(xml-escape $classname)" name="(xml-escape $name)">
      <failure message="($message)"><![CDATA[($raw_message)

How to fix:
($raw_fix)]]></failure>
    </testcase>'
        }
    }
    let failures = ($results | where status == failure | length)
    let content = [
        '<?xml version="1.0" encoding="UTF-8"?>'
        $'<testsuites name="(xml-escape $title)" tests="($results | length)" failures="($failures)">'
        $'  <testsuite name="(xml-escape $title)" tests="($results | length)" failures="($failures)">'
        ($testcases | str join (char nl))
        (if ($cgo_notice | is-empty) { '' } else { $'    <system-out><![CDATA[(xml-cdata $cgo_notice)]]></system-out>' })
        '  </testsuite>'
        '</testsuites>'
        ''
    ] | str join (char nl)
    $content | save --force $junit_file
}

def project-directories-or-error []: nothing -> list<string> {
    let directories = project-directories
    if ($directories | is-empty) {
        error make {msg: $'No supported language project found under (project).'}
    }
    $directories
}

def run-category-checks [category: string]: nothing -> record {
    let scope = (project)
    cd $scope
    let directories = project-directories-or-error
    mut results = []
    for directory in $directories {
        let languages = project-languages $directory
        let relative = ($directory | path relative-to $scope)
        let display = if ($relative | is-empty) or $relative == '.' { '.' } else { $relative }
        log info $'Discovered project ($display): ($languages | str join ", ")'
        for language in $languages {
            for command in (checks-for-category $category $language) {
                $results = ($results | append (run-project-check $directory $language $command.0 $command.2))
            }
        }
    }
    { scope: $scope, directories: $directories, results: $results }
}

def run-category [category: string] {
    if $category not-in [format lint strlint typecheck] {
        error make {msg: $'Unknown quality-gate category: ($category)'}
    }
    let run = run-category-checks $category
    let title = ($category | str capitalize)
    write-reports $title $run.scope $run.results
    let failures = $run.results | where status == failure
    if ($run.results | is-empty) {
        log warning $'No ($category) checks apply to the discovered projects.'
    }
    if not ($failures | is-empty) {
        let failure_count = ($failures | length)
        let result_count = ($run.results | length)
        let project_count = ($run.directories | length)
        if not (report-only) {
            error make {msg: $"($title) failed: ($failure_count) of ($result_count) checks failed across ($project_count) projects."}
        }
        log warning $'REPORT-ONLY: ($title) found ($failure_count) of ($result_count) failed checks across ($project_count) projects.'
    }
}

def detect [] {
    let scope = (project)
    cd $scope
    let directories = project-directories-or-error
    let languages = $directories | each {|directory| project-languages $directory } | flatten | uniq | sort
    for directory in $directories {
        let relative = ($directory | path relative-to $scope)
        let display = if ($relative | is-empty) or $relative == '.' { '.' } else { $relative }
        log info $'Detected project ($display): ((project-languages $directory) | str join ", ")'
        if python in (project-languages $directory) {
            cd $directory
            warn-unsupported-python-manager $display
            cd $scope
        }
    }

    let detection_file = ($env.QUALITY_GATE_DETECTION_FILE? | default null)
    if $detection_file != null {
        let content = [
            $'QUALITY_GATE_PROJECT_COUNT=($directories | length)'
            $'QUALITY_GATE_LANGUAGES=($languages | str join ",")'
            $'QUALITY_GATE_HAS_PYTHON=(if python in $languages { "true" } else { "false" })'
            $'QUALITY_GATE_HAS_GO=(if go in $languages { "true" } else { "false" })'
            $'QUALITY_GATE_HAS_TYPESCRIPT=(if typescript in $languages { "true" } else { "false" })'
            ''
        ] | str join (char nl)
        $content | save --append $detection_file
    }
}

def test [] {
    let run = run-category-checks test
    write-reports 'Tests' $run.scope $run.results
    let failures = $run.results | where status == failure
    if ($run.results | is-empty) {
        error make {msg: 'No test runner was found for the discovered projects.'}
    }
    if not ($failures | is-empty) {
        let failure_count = ($failures | length)
        let result_count = ($run.results | length)
        error make {msg: $"Tests failed: ($failure_count) of ($result_count) test runners failed. Report-only mode applies to the static checks, never to the project's own tests."}
    }
}

def ci [] {
    let scope = (project)
    cd $scope
    let categories = [format lint strlint typecheck]
    mut results = []
    mut directories = []
    for category in $categories {
        let run = run-category-checks $category
        $results = ($results | append $run.results)
        $directories = (($directories | append $run.directories) | uniq)
    }
    write-reports 'All static checks' $scope $results
    let failures = $results | where status == failure
    if not ($failures | is-empty) {
        let failure_count = ($failures | length)
        let result_count = ($results | length)
        if not (report-only) {
            error make {msg: $"Quality gate failed: ($failure_count) of ($result_count) checks failed across ($directories | length) projects."}
        }
        log warning $'REPORT-ONLY: quality gate found ($failure_count) of ($result_count) failed checks.'
    }
}

def run-command [verb: string, language: string, check: string] {
    cd (project)
    let environment = if $language == go { {CGO_ENABLED: '0'} } else { {} }
    with-env $environment {
        run-command-inner $verb $language $check
    }
}

def run-command-inner [verb: string, language: string, check: string] {
    match [$verb $language $check] {
        [format python ruff] => (format-python)
        [lint python ruff] => (lint-python)
        [lint python complexipy] => (lint-python-complexipy)
        [typecheck python basedpyright] => (typecheck-python-basedpyright)
        [lint python strlint] => (lint-strlint python $env.QUALITY_GATE_PYTHON_RULES)
        [format go gofumpt] => (format-go-gofumpt)
        [format go goimports] => (format-go-goimports)
        [lint go golangci] => (lint-go-golangci)
        [lint go strlint] => (lint-strlint go $env.QUALITY_GATE_GO_RULES)
        [lint go vet] => (lint-go-vet)
        [typecheck go build] => (typecheck-go)
        [format typescript oxfmt] => (format-typescript)
        [lint typescript oxlint] => (lint-typescript-oxlint)
        [lint typescript strlint] => (lint-strlint typescript $env.QUALITY_GATE_TYPESCRIPT_RULES)
        [typecheck typescript tsc] => (typecheck-typescript)
        [test python pytest] => (test-python)
        [test go test] => (test-go)
        [test typescript test] => (test-typescript)
        _ => (error make {msg: $'Unknown quality-gate check: ($verb) ($language) ($check)'})
    }
}

def main [verb?: string, language?: string, check?: string] {
    if $verb == qg {
        if $language == null or $check == null or $language not-in [format lint strlint typecheck tests] {
            print 'Usage: qg <format|lint|strlint|typecheck|tests> <py|python|go|ts|typescript>'
            exit 2
        }
        let category = if $language == tests { 'test' } else { $language }
        run-language-category $category $check
        return
    }
    if $verb == ci {
        ci
        return
    }
    if $verb == detect {
        detect
        return
    }
    if $verb == category {
        if $language == null {
            print 'Usage: quality-gate.nu category <format|lint|strlint|typecheck>'
            exit 2
        }
        if $language not-in [format lint strlint typecheck] {
            print 'Usage: quality-gate.nu category <format|lint|strlint|typecheck>'
            exit 2
        }
        run-category $language
        return
    }
    if $verb == test {
        test
        return
    }
    if $verb == hook {
        if $language == null {
            print 'Usage: quality-gate.nu hook <py|python|go|ts|typescript>'
            exit 2
        }
        run-language-ci $language
        return
    }
    if $verb == fix {
        if $language == null {
            print 'Usage: quality-gate.nu fix <py|python|go|ts|typescript>'
            exit 2
        }
        fix-language $language
        return
    }
    if $language != null and $check == null and $verb in [format lint strlint typecheck tests] {
        let category = if $verb == tests { 'test' } else { $verb }
        run-language-category $category $language
        return
    }
    if $verb not-in [format lint strlint typecheck test tests] {
        print 'Usage: quality-gate.nu ci | detect | category <format|lint|strlint|typecheck> | test | <format|lint|strlint|typecheck|tests> <py|python|go|ts|typescript>'
        exit 2
    }
    if $verb == null or $language == null or $check == null {
        print 'Usage: quality-gate.nu ci | detect | category <format|lint|strlint|typecheck> | test | <format|lint> <python|go|typescript> <check> | <format|lint|strlint|typecheck|tests> <py|python|go|ts|typescript>'
        exit 2
    }
    # Individual checks bypass the aggregate report, so show their cgo notice
    # here instead. Formatting and structural checks still inspect those files.
    let name = $'($verb):($language):($check)'
    if $language == go and $name in ['lint:go:golangci' 'lint:go:vet' 'typecheck:go:build'] {
        let scope = project
        if (($scope | path join go.mod) | path exists) {
            let notice = go-cgo-notice $scope [{project: $scope, language: go, check: $name}]
            if ($notice | is-not-empty) { print $notice }
        }
    }
    run-command $verb $language $check
}

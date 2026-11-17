#!/usr/bin/env nu

use std/log

const PYTHON_PROJECT_FILES = [pyproject.toml setup.py]
const IGNORED_DIRECTORY_NAMES = [
    .git node_modules vendor .venv __pycache__ .cache
    dist build out .next .nuxt coverage
]
const IGNORED_TEST_PATH_NAMES = [
    .git node_modules vendor .venv __pycache__ .cache dist build out .next .nuxt coverage
]

def project []: nothing -> path {
    $env.QUALITY_GATE_PROJECT_DIR? | default '.' | path expand
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
        ^git -C $git_root ls-files --cached --others --exclude-standard
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
            $changed | any {|file|
                $file == $directory or ($file | str starts-with ($'($directory)/'))
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
        error make {msg: 'No local tests were found'}
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
    true
}

def capture [command: string, arguments: list<string>]: nothing -> record {
    run-external $command ...$arguments | complete
}

def record-output [text: string] {
    let output_file = ($env.QUALITY_GATE_CHECK_OUTPUT? | default null)
    if $output_file == null or ($text | is-empty) { return }
    let previous = if ($output_file | path exists) { open --raw $output_file } else { '' }
    ($previous + $text + (char nl)) | save --force $output_file
}

def run-check [name: string, command: string, arguments: list<string>] {
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
        error make {msg: $'($name) failed with exit code ($result.exit_code)'}
    }
}

def warn-local-quality-config [files: list<string>] {
    let found = $files | where {|file| ($file | path exists) }
    if ($found | is-not-empty) {
        log warning $'Ignoring local quality configuration (($found | str join ", ")); the central Quality Gate configuration is mandatory.'
    }
}

def quality-gate-exclude-patterns []: nothing -> list<string> {
    let file = project | path join .quality-gate exclude
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
        ^git -C $root ls-files --cached --others --exclude-standard
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
        let result = ($input | ^git -C $temporary check-ignore --no-index --stdin | complete)
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
        error make {msg: $'Invalid .quality-gate/exclude pattern(s): (($broad | str join ", ")). Broad patterns cannot disable the Quality Gate.'}
    }

    let scope = project
    let files = git-repository-files $scope
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
    let relative = $candidate | path relative-to (project)
    (git-excluded-relative [$relative] | is-not-empty)
}

def quality-gate-files [extensions: list<string>]: nothing -> list<string> {
    let scope = project
    let tracked = git-repository-files $scope
    let files = if ($tracked | is-empty) {
        glob --no-dir ($'($scope)/**/*')
    } else {
        $tracked
    }
    let excluded = git-excluded-relative ($files | each {|file| $file | path relative-to $scope })
    $files
    | where {|file|
        let extension = (($file | path parse).extension? | default '' | str lowercase)
        $extension in $extensions
    }
    | each {|file| $file | path relative-to $scope }
    | where {|file| $file not-in $excluded }
}

def exclusion-arguments [flag: string]: nothing -> list<string> {
    quality-gate-exclude-patterns
    | each {|pattern| [$flag $pattern] }
    | flatten
}

def sync-python []: nothing -> nothing {
    if not ('pyproject.toml' | path exists) {
        error make {msg: 'Python typecheck/tests require pyproject.toml managed by uv; setup.py-only projects are unsupported for dependency-aware checks.'}
    }
    if not ('uv.lock' | path exists) {
        error make {msg: 'Python typecheck/tests require uv.lock. Run `uv lock` and commit the lockfile.'}
    }

    let marker = '.venv/.quality-gate-uv-sync'
    let fingerprint = ([ (open --raw pyproject.toml) (open --raw uv.lock) ] | str join (char nul) | hash sha256 | str trim)
    let current = if ($marker | path exists) { open --raw $marker | str trim } else { '' }
    if $current == $fingerprint {
        log info 'uv dependencies are up to date; skipping uv sync.'
    } else {
        run-check 'uv sync' uv [sync --frozen --all-groups]
        mkdir .venv
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

    let files = quality-gate-files [py pyi]
    if ($files | is-empty) {
        log warning 'No Python source files remain after .quality-gate/exclude; skipping format.'
        return
    }
    let arguments = [format --check --config $env.QUALITY_GATE_RUFF_CONFIG]
        ++ $files
    let result = capture ruff $arguments
    if $result.exit_code == 0 {
        print 'ruff format: all files are correctly formatted.'
        return
    }

    if ($result.stdout | is-not-empty) { print ($result.stdout | str trim) }
    if ($result.stderr | is-not-empty) { print -e ($result.stderr | str trim) }
    let diff = capture ruff ([format --diff --config $env.QUALITY_GATE_RUFF_CONFIG] ++ $files)
    if ($diff.stdout | is-not-empty) { print ($diff.stdout | str trim) }
    error make {msg: 'ruff format found formatting differences; run `qg format py`'}
}

def lint-python [] {
    if not (python-project) { return }
    warn-local-quality-config ['ruff.toml' '.ruff.toml']
    let files = quality-gate-files [py pyi]
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
    if (quality-gate-files [py pyi] | is-empty) {
        log warning 'No Python source files remain after .quality-gate/exclude; skipping complexity.'
        return
    }
    run-check 'complexipy' complexipy [.]
}

def lint-python-basedpyright [] {
    if not (python-project) { return }
    sync-python
    warn-local-quality-config ['pyrightconfig.json']
    let config = (python-quality-config)
    let arguments = [--project $config]
    let python = (project | path join .venv bin python)
    let arguments = if ($python | path exists) {
        $arguments ++ [--pythonpath $python]
    } else {
        $arguments
    }
    try {
        run-check 'basedpyright' basedpyright ($arguments ++ [.])
    } finally {
        rm $config
    }
}

def python-quality-config []: nothing -> path {
    let central = open $env.QUALITY_GATE_PYRIGHT_CONFIG
    let scope = project
    let files = git-repository-files $scope
    let excludes = git-excluded-relative (
        $files | each {|file| $file | path relative-to $scope }
    ) | each {|file| $scope | path join $file | path expand }
    let config = project | path join '.quality-gate-pyrightconfig.json'
    rm --force $config
    $central
    | upsert exclude $excludes
    | to json
    | save --force $config
    $config
}

def ast-grep-config [rules: path, language: string]: nothing -> path {
    let config = (mktemp | str trim)
    let scope = project
    let files = git-repository-files $scope
    let ignores = git-excluded-relative (
        $files | each {|file| $file | path relative-to $scope }
    )
    let ignore_lines = if ($ignores | is-empty) {
        []
    } else {
        ['ignores:'] ++ ($ignores | each {|pattern| $'  - ($pattern)'})
    }
    let content = if $language == typescript {
        [
            'ruleDirs:'
            $'  - ($rules)'
            ...$ignore_lines
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
        (['ruleDirs:' $'  - ($rules)'] ++ $ignore_lines)
        | str join (char nl)
        | $in + (char nl)
    }
    $content | save --force $config
    $config
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
        run-check $'($language) organizational ast-grep rules' ast-grep [scan --config $central]
    } finally {
        rm $central
    }

    let local = local-ast-grep-config
    if $local == null {
        log info 'No repository-local ast-grep rules found; skipping.'
    } else {
        try {
            run-check $'($language) repository ast-grep rules' ast-grep [scan --config $local.path]
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
    let files = quality-gate-files [go]
    if ($files | is-empty) {
        log warning 'No Go source files remain after .quality-gate/exclude; skipping format.'
        return
    }
    let result = capture gofumpt ([-l] ++ $files)
    if $result.exit_code != 0 {
        error make {msg: 'gofumpt could not inspect the project'}
    }
    if ($result.stdout | str trim | is-empty) {
        print 'gofumpt: all files are correctly formatted.'
    } else {
        print ($result.stdout | str trim)
        let diff = capture gofumpt ([-d] ++ $files)
        if ($diff.stdout | is-not-empty) { print ($diff.stdout | str trim) }
        error make {msg: 'gofumpt found unformatted files; run `gofumpt -w .`'}
    }
}

def format-go-goimports [] {
    if not (go-project) { return }
    let files = quality-gate-files [go]
    if ($files | is-empty) {
        log warning 'No Go source files remain after .quality-gate/exclude; skipping imports format.'
        return
    }
    let result = capture goimports ([-l] ++ $files)
    if $result.exit_code != 0 {
        error make {msg: 'goimports could not inspect the project'}
    }
    if ($result.stdout | str trim | is-empty) {
        print 'goimports: all import blocks are correctly organised.'
    } else {
        print ($result.stdout | str trim)
        let diff = capture goimports ([-d] ++ $files)
        if ($diff.stdout | is-not-empty) { print ($diff.stdout | str trim) }
        error make {msg: 'goimports found unorganised imports; run `goimports -w .`'}
    }
}

def lint-go-golangci [] {
    if not (go-project) { return }
    warn-local-quality-config ['.golangci.yml' '.golangci.yaml' '.golangci.toml' '.golangci.json']
    let config = (go-quality-config)
    try {
        run-check 'golangci-lint' golangci-lint [run --config $config]
    } finally {
        rm $config
    }
}

def go-quality-config []: nothing -> path {
    let central = open $env.QUALITY_GATE_GO_CONFIG
    let scope = project
    let files = git-repository-files $scope
    let paths = git-excluded-relative (
        $files | each {|file| $file | path relative-to $scope }
    ) | each {|path| $path | str replace --all '.' '\.' }
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
    let result = capture go [list -f '{{.ImportPath}}\t{{.Dir}}' ./...]
    if $result.exit_code != 0 {
        error make {msg: 'go list could not inspect the project'}
    }
    $result.stdout
    | lines
    | each {|line|
        let parts = $line | split row (char tab)
        { package: ($parts | get 0), directory: ($parts | get 1) }
    }
    | where {|row| not (quality-gate-path-excluded $row.directory) }
    | get package
}

def node-manager []: nothing -> string {
    if ('pnpm-lock.yaml' | path exists) {
        let package = open package.json
        let declaration = ($package.packageManager? | default '')
        if (($declaration | describe) != string) or not ($declaration =~ '^pnpm@[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$') {
            error make {msg: 'pnpm-lock.yaml requires package.json packageManager: pnpm@<version>.'}
        }
        'pnpm'
    } else if ('package-lock.json' | path exists) {
        'npm'
    } else {
        error make {msg: 'No lockfile found. Commit package-lock.json (npm) or pnpm-lock.yaml (pnpm).'}
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
    let lockfile = if $manager == npm { 'package-lock.json' } else { 'pnpm-lock.yaml' }
    let fingerprint = [
        (open --raw package.json)
        (open --raw $lockfile)
        (if ('.node-version' | path exists) { open --raw .node-version } else { $env.QUALITY_GATE_NODE_VERSION? | default '' })
    ] | str join (char nul) | hash sha256 | str trim
    let marker = 'node_modules/.quality-gate-dependencies'
    let current = if ($marker | path exists) { open --raw $marker | str trim } else { '' }
    if $current == $fingerprint {
        log info 'Node dependencies are up to date; skipping install.'
        return
    }
    if $manager == npm {
        run-check 'npm ci' npm [ci]
    } else {
        run-check 'pnpm install' pnpm [install --frozen-lockfile]
    }
    mkdir node_modules
    $fingerprint | save --force $marker
}

def validate-node-version []: nothing -> nothing {
    let configured = ($env.QUALITY_GATE_NODE_VERSION? | default '')
    if not ('.node-version' | path exists) and ($configured | is-empty) {
        error make {msg: 'Missing .node-version for TypeScript typecheck. Add the Node.js major version used by the project.'}
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
    let files = quality-gate-files [ts tsx mts cts vue]
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
        error make {msg: 'oxfmt found formatting differences; run `qg format ts`'}
    }
}

def lint-typescript-oxlint [] {
    if not (node-project) { return }
    warn-local-quality-config ['.oxlintrc.json' '.oxlintrc.yaml' '.oxlintrc.yml' 'oxlint.config.js' 'oxlint.config.mjs' 'oxlint.config.ts']
    let source_files = quality-gate-files [ts tsx mts cts vue]
    if ($source_files | is-empty) {
        log warning 'No TypeScript source files remain after .quality-gate/exclude; skipping lint.'
        return
    }
    let paths = (
        [--config $env.QUALITY_GATE_OXLINT_CONFIG]
        ++ $source_files
    )
    let framework = typescript-framework
    let arguments = if $framework == next {
        [--react-plugin --jsx-a11y-plugin --nextjs-plugin --ignore-pattern '.next/**' --ignore-pattern 'out/**'] ++ $paths
    } else if (typescript-react-project) {
        [--react-plugin --jsx-a11y-plugin] ++ $paths
    } else {
        $paths
    }
    run-check 'oxlint' oxlint $arguments
}

def lint-typescript-typecheck [] {
    if not (node-project) { return }
    validate-node-version
    install-node-dependencies
    let manager = node-manager
    let configs = (typescript-quality-configs)
    let framework = typescript-framework
    try {
        if $framework == nuxt {
            if $manager == npm {
                run-check 'nuxt prepare' npm [exec --no -- nuxt prepare]
            } else {
                run-check 'nuxt prepare' pnpm [exec nuxt prepare]
            }
        }
        for config in $configs {
            if $framework in [vue nuxt] {
                if $manager == npm {
                    run-check 'vue-tsc' npm [exec -- vue-tsc --noEmit --project $config]
                } else {
                    run-check 'vue-tsc' pnpm [exec vue-tsc --noEmit --project $config]
                }
            } else {
                if $manager == npm {
                    run-check 'tsc' npm [exec -- tsc --noEmit --project $config]
                } else {
                    run-check 'tsc' pnpm [exec tsc --noEmit --project $config]
                }
            }
        }
    } finally {
        for config in $configs {
            rm $config
        }
    }
}

def typescript-show-config [config: path]: nothing -> record {
    let result = capture tsc [--showConfig --project $config]
    if $result.exit_code != 0 {
        error make {msg: $'Could not expand TypeScript config ($config): ($result.stderr | str trim)'}
    }
    try {
        $result.stdout | from json
    } catch {|error|
        error make {msg: $'Could not parse TypeScript config ($config): ($error.msg)'}
    }
}

def typescript-project-file [base: path, file: string]: nothing -> path {
    if ($file | str starts-with '/') {
        $file | path expand
    } else {
        $base | path join $file | path expand
    }
}

def typescript-quality-configs []: nothing -> list<path> {
    let central = (open $env.QUALITY_GATE_TYPESCRIPT_CONFIG)
    let root_config = $env.PWD | path join 'tsconfig.json' | path expand
    let root = (typescript-show-config $root_config)
    let references = ($root.references? | default [])
    let sources = if ($references | is-empty) {
        [{ base: ($root_config | path dirname), config: $root_config, effective: $root }]
    } else {
        $references | each {|reference|
            let config = typescript-project-file ($root_config | path dirname) $reference.path
            {
                base: ($config | path dirname)
                config: $config
                effective: (typescript-show-config $config)
            }
        }
    }

    $sources | each {|source|
        let effective = $source.effective
        let options = ($effective.compilerOptions? | default {}) | merge $central.compilerOptions
        let files = ($effective.files? | default [])
            | each {|file| typescript-project-file $source.base $file }
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
}

def test-python [] {
    require-local-tests python
    sync-python
    run-check 'uv pytest' uv [run pytest]
}

def test-go [] {
    require-local-tests go
    run-check 'go test' go [test ./...]
}

def test-typescript [] {
    require-local-tests typescript
    validate-node-version
    if not (package-has-script test) {
        error make {msg: 'TypeScript projects must define scripts.test in package.json.'}
    }
    install-node-dependencies
    let manager = node-manager
    if $manager == npm {
        run-check 'npm test' npm [run test]
    } else {
        run-check 'pnpm test' pnpm [run test]
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
        [typecheck python] => [[lint python basedpyright]]
        [typecheck go] => [[typecheck go build]]
        [typecheck typescript] => [[lint typescript typecheck]]
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
            [lint python basedpyright]
            [lint python strlint]
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
            [lint typescript typecheck]
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

    print-console-summary $'($normalized) hook checks' $scope $results
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
    cd $scope
    for directory in (project-directories) {
        if $normalized not-in (project-languages $directory) {
            continue
        }
        cd $directory
        match $normalized {
            python => {
                run-fix-check 'ruff format' ruff [format --config $env.QUALITY_GATE_RUFF_CONFIG .]
                run-fix-check 'ruff check --fix' ruff [check --config $env.QUALITY_GATE_RUFF_CONFIG --fix .]
            }
            go => {
                run-fix-check 'gofumpt' gofumpt [-w .]
                run-fix-check 'goimports' goimports [-w .]
            }
            typescript => {
                run-fix-check 'oxfmt' oxfmt [--config $env.QUALITY_GATE_OXFMT_CONFIG --write .]
            }
        }
        cd $scope
    }
}

def report-language-checks [title: string, language: string, commands: list<list<string>>] {
    let run = run-language-checks $language $commands
    print-console-summary $title $run.scope $run.results
    write-summary $title $run.scope $run.results
    write-junit $title $run.scope $run.results
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
    let normalized = normalize-language $language
    report-language-checks ($'($normalized) ($category)') $normalized (checks-for-category $category $normalized)
}

def check-fix [verb: string, language: string, check: string]: nothing -> string {
    match [$verb $language $check] {
        [format python ruff] => 'ruff format --config $QUALITY_GATE_RUFF_CONFIG .'
        [lint python ruff] => 'ruff check --config $QUALITY_GATE_RUFF_CONFIG --fix .'
        [lint python complexipy] => 'complexipy .'
        [lint python basedpyright] => 'basedpyright --project $QUALITY_GATE_PYRIGHT_CONFIG .'
        [lint python strlint] => 'ast-grep scan'
        [format go gofumpt] => 'gofumpt -w .'
        [format go goimports] => 'goimports -w .'
        [lint go golangci] => 'golangci-lint run --config $QUALITY_GATE_GO_CONFIG'
        [lint go strlint] => 'ast-grep scan'
        [lint go vet] => 'go vet ./...'
        [lint go build] => 'go build ./...'
        [typecheck go build] => 'go build ./...'
        [format typescript oxfmt] => 'oxfmt --config $QUALITY_GATE_OXFMT_CONFIG --write .'
        [lint typescript oxlint] => 'oxlint --config $QUALITY_GATE_OXLINT_CONFIG .'
        [lint typescript strlint] => 'ast-grep scan'
        [lint typescript typecheck] => 'qg typecheck ts'
        [test python pytest] => 'uv run pytest'
        [test go test] => 'go test ./...'
        [test typescript test] => (if ('pnpm-lock.yaml' | path exists) { 'pnpm test' } else { 'npm test' })
        _ => 'See the quality-gate task output above.'
    }
}

def run-project-check [directory: string, language: string, verb: string, check: string]: nothing -> record {
    let output_file = (mktemp | str trim)
    let result = try {
        with-env {
            QUALITY_GATE_PROJECT_DIR: $directory
            QUALITY_GATE_CHECK_OUTPUT: $output_file
        } {
            run-command $verb $language $check
        }
        { status: 'success', error: '' }
    } catch {|err|
        {
            status: 'failure'
            error: ($err.msg? | default ($err | to text))
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
        error: $error
        fix: (check-fix $verb $language $check)
    }
}

def xml-escape [value: string]: nothing -> string {
    $value
    | str replace --all '&' '&amp;'
    | str replace --all '<' '&lt;'
    | str replace --all '>' '&gt;'
    | str replace --all '"' '&quot;'
    | str replace --all "'" '&apos;'
}

def xml-cdata [value: string]: nothing -> string {
    $value | str replace --all ']]>' ']]]]><![CDATA[>'
}

def result-project [result: record, scope: string]: nothing -> string {
    let relative = ($result.project | path relative-to $scope)
    if ($relative | is-empty) or $relative == '.' { '.' } else { $relative }
}

def print-console-summary [title: string, scope: string, results: list<record>] {
    let failures = $results | where status == failure
    let revision = $env.QUALITY_GATE_REVISION? | default 'unknown'
    print ''
    print $'Quality Gate — ($title)'
    print $'Scope: ($scope)'
    print $'Revision: ($revision)'
    print $'Mode: (if (report-only) { "report-only" } else { "blocking" })'
    let exclusions = quality-gate-exclude-patterns
    print $'Exclusions: (if ($exclusions | is-empty) { "none" } else { $exclusions | str join ", " })'
    print ''
    print '| Project | Language | Check | Outcome |'
    print '| --- | --- | --- | --- |'
    for result in $results {
        let outcome = if $result.status == success { '✅ PASS' } else { '❌ FAIL' }
        print $'| `((result-project $result $scope))` | `($result.language)` | `($result.check)` | ($outcome) |'
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
            print $failure.error
            print $'How to fix: ($failure.fix)'
            print ''
        }
    }
    print ''
}

def write-summary [title: string, scope: string, results: list<record>] {
    let summary_file = ($env.QUALITY_GATE_SUMMARY_FILE? | default null)
    if $summary_file == null { return }

    let rows = $results | each {|result|
        let display_project = result-project $result $scope
        let outcome = if $result.status == 'success' { '✅ success' } else { '❌ failure' }
        $'| `($display_project)` | `($result.language)` | `($result.check)` | ($outcome) |'
    }
    let failures = $results | where status == failure
    let details = if ($failures | is-empty) {
        ['All discovered projects passed their quality checks.']
    } else {
        $failures | each {|failure|
            let display_project = result-project $failure $scope
            $'### `($display_project)` / ($failure.language) / `($failure.check)`

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
        (if (report-only) { '> REPORT-ONLY: failures are reported but do not block this execution.' } else { '' })
        ''
        '| Project | Language | Check | Outcome |'
        '| --- | --- | --- | --- |'
        ($rows | str join (char nl))
        ''
        '## Failure details'
        ''
        ($details | str join (char nl + char nl))
        ''
    ] | str join (char nl)
    $content | save --force $summary_file
}

def write-junit [title: string, scope: string, results: list<record>] {
    let junit_file = ($env.QUALITY_GATE_JUNIT_FILE? | default null)
    if $junit_file == null { return }

    let testcases = $results | each {|result|
        let project = result-project $result $scope
        let name = $'($project) / ($result.check)'
        let classname = $'($project).($result.language)'
        if $result.status == success {
            $'    <testcase classname="(xml-escape $classname)" name="(xml-escape $name)" />'
        } else {
            let message = xml-escape $result.error
            let raw_message = xml-cdata $result.error
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
    let run = run-category-checks $category
    let title = ($category | str capitalize)
    print-console-summary $title $run.scope $run.results
    write-summary $title $run.scope $run.results
    write-junit $title $run.scope $run.results
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
        $content | save --force $detection_file
    }
}

def test [] {
    let run = run-category-checks test
    print-console-summary 'Tests' $run.scope $run.results
    write-summary 'Tests' $run.scope $run.results
    write-junit 'Tests' $run.scope $run.results
    let failures = $run.results | where status == failure
    if ($run.results | is-empty) {
        error make {msg: 'No test runner was found for the discovered projects.'}
    }
    if not ($failures | is-empty) {
        let failure_count = ($failures | length)
        let result_count = ($run.results | length)
        if not (report-only) {
            error make {msg: $"Tests failed: ($failure_count) of ($result_count) test runners failed."}
        }
        log warning $'REPORT-ONLY: tests found ($failure_count) failed test runners.'
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
    print-console-summary 'All static checks' $scope $results
    write-summary 'All static checks' $scope $results
    write-junit 'All static checks' $scope $results
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

    match [$verb $language $check] {
        [format python ruff] => (format-python)
        [lint python ruff] => (lint-python)
        [lint python complexipy] => (lint-python-complexipy)
        [lint python basedpyright] => (lint-python-basedpyright)
        [lint python strlint] => (lint-strlint python $env.QUALITY_GATE_PYTHON_RULES)
        [format go gofumpt] => (format-go-gofumpt)
        [format go goimports] => (format-go-goimports)
        [lint go golangci] => (lint-go-golangci)
        [lint go strlint] => (lint-strlint go $env.QUALITY_GATE_GO_RULES)
        [lint go vet] => (lint-go-vet)
        [lint go build] => (typecheck-go)
        [typecheck go build] => (typecheck-go)
        [format typescript oxfmt] => (format-typescript)
        [lint typescript oxlint] => (lint-typescript-oxlint)
        [lint typescript strlint] => (lint-strlint typescript $env.QUALITY_GATE_TYPESCRIPT_RULES)
        [lint typescript typecheck] => (lint-typescript-typecheck)
        [typecheck typescript] => (lint-typescript-typecheck)
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
    if $verb == null or $language == null or $check == null {
        print 'Usage: quality-gate.nu ci | detect | category <format|lint|strlint|typecheck> | test | <format|lint> <python|go|typescript> <check> | <format|lint|strlint|typecheck|tests> <py|python|go|ts|typescript>'
        exit 2
    }
    run-command $verb $language $check
}

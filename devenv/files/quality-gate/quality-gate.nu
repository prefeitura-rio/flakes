#!/usr/bin/env nu

use std/log

const PYTHON_PROJECT_FILES = [pyproject.toml setup.py]
const IGNORED_DIRECTORY_NAMES = [
    .git .github .gitlab node_modules vendor .venv __pycache__ .cache
    dist build out .next .nuxt coverage docs doc documentation
    scripts tools bin hack infra deploy k8s helm test tests spec e2e fixtures
    testdata ci .ci pipeline pipelines
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

def ignored-project-path [directory: string, scope: string]: nothing -> bool {
    let relative = ($directory | path relative-to $scope)
    let parts = ($relative | path split)
    $parts | any {|part|
        ($part | str starts-with '.') or ($part in $IGNORED_DIRECTORY_NAMES)
    }
}

def project-directories []: nothing -> list<string> {
    let scope = (project)
    let marker_files = [
        (glob --no-dir ($'($scope)/**/go.mod'))
        (glob --no-dir ($'($scope)/**/pyproject.toml'))
        (glob --no-dir ($'($scope)/**/setup.py'))
        (glob --no-dir ($'($scope)/**/package.json'))
    ] | flatten

    $marker_files
    | each {|file| $file | path dirname }
    | uniq
    | where {|directory| not (ignored-project-path $directory $scope) }
    | where {|directory| (project-languages $directory) | is-not-empty }
    | sort
}

def skip [language: string] {
    log warning $'No ($language) project was found in ($env.PWD); skipping.'
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

def project-has-ruff-config []: nothing -> bool {
    if (['ruff.toml' '.ruff.toml'] | any {|file| $file | path exists}) {
        true
    } else if ('pyproject.toml' | path exists) {
        (open --raw pyproject.toml | str contains '[tool.ruff')
    } else {
        false
    }
}

def sync-python []: nothing -> nothing {
    if ('pyproject.toml' | path exists) {
        run-check 'uv sync' uv [sync --frozen --all-groups]
    } else {
        log warning 'No pyproject.toml found; dependency synchronization was skipped.'
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

def format-python [] {
    if not (python-project) { return }
    sync-python

    let result = capture ruff [format --check .]
    if $result.exit_code == 0 {
        print 'ruff format: all files are correctly formatted.'
        return
    }

    if ($result.stdout | is-not-empty) { print ($result.stdout | str trim) }
    if ($result.stderr | is-not-empty) { print -e ($result.stderr | str trim) }
    let diff = capture ruff [format --diff .]
    if ($diff.stdout | is-not-empty) { print ($diff.stdout | str trim) }
    error make {msg: 'ruff format found formatting differences; run `ruff format .`'}
}

def lint-python [] {
    if not (python-project) { return }
    sync-python

    let arguments = if (project-has-ruff-config) {
        [check .]
    } else {
        [check --config $env.QUALITY_GATE_RUFF_CONFIG .]
    }
    run-check 'ruff check' ruff $arguments
}

def lint-python-complexipy [] {
    if not (python-project) { return }
    sync-python

    run-check 'complexipy' complexipy [.]
}

def lint-python-basedpyright [] {
    if not (python-project) { return }
    sync-python

    let pyproject = if ('pyproject.toml' | path exists) { open --raw pyproject.toml } else { '' }
    let arguments = if ('pyrightconfig.json' | path exists) or ($pyproject | str contains '[tool.basedpyright') or ($pyproject | str contains '[tool.pyright') {
        [--project ($env.PWD | path expand)]
    } else {
        [--project $env.QUALITY_GATE_PYRIGHT_CONFIG .]
    }
    run-check 'basedpyright' basedpyright $arguments
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
        ['ruleDirs:' $'  - ($rules)'] | str join (char nl) | $in + (char nl)
    }
    $content | save --force $config
    $config
}

def local-ast-grep-config []: nothing -> oneof<string, nothing> {
    if ('sgconfig.yaml' | path exists) {
        'sgconfig.yaml'
    } else if ('rules' | path type) == dir {
        let config = (mktemp | str trim)
        ['ruleDirs:' '  - rules'] | str join (char nl) | $in + (char nl) | save --force $config
        $config
    } else if ('.quality-gate/sgconfig.yaml' | path exists) {
        '.quality-gate/sgconfig.yaml'
    } else if ('.quality-gate/rules' | path type) == dir {
        let config = (mktemp | str trim)
        ['ruleDirs:' '  - .quality-gate/rules'] | str join (char nl) | $in + (char nl) | save --force $config
        $config
    } else {
        null
    }
}

def lint-strlint [language: string, rules: path] {
    let central = ast-grep-config $rules $language
    run-check $'($language) organizational ast-grep rules' ast-grep [scan --config $central]

    let local = local-ast-grep-config
    if $local == null {
        log info 'No repository-local ast-grep rules found; skipping.'
    } else {
        run-check $'($language) repository ast-grep rules' ast-grep [scan --config $local]
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
    let result = capture gofumpt [-l .]
    if $result.exit_code != 0 {
        error make {msg: 'gofumpt could not inspect the project'}
    }
    if ($result.stdout | str trim | is-empty) {
        print 'gofumpt: all files are correctly formatted.'
    } else {
        print ($result.stdout | str trim)
        let diff = capture gofumpt [-d .]
        if ($diff.stdout | is-not-empty) { print ($diff.stdout | str trim) }
        error make {msg: 'gofumpt found unformatted files; run `gofumpt -w .`'}
    }
}

def format-go-goimports [] {
    if not (go-project) { return }
    let result = capture goimports [-l .]
    if $result.exit_code != 0 {
        error make {msg: 'goimports could not inspect the project'}
    }
    if ($result.stdout | str trim | is-empty) {
        print 'goimports: all import blocks are correctly organised.'
    } else {
        print ($result.stdout | str trim)
        let diff = capture goimports [-d .]
        if ($diff.stdout | is-not-empty) { print ($diff.stdout | str trim) }
        error make {msg: 'goimports found unorganised imports; run `goimports -w .`'}
    }
}

def lint-go-golangci [] {
    if not (go-project) { return }
    let arguments = if (['.golangci.yml' '.golangci.yaml'] | any {|file| $file | path exists}) {
        [run]
    } else {
        [run --config $env.QUALITY_GATE_GO_CONFIG]
    }
    run-check 'golangci-lint' golangci-lint $arguments
}

def lint-go-vet [] {
    if not (go-project) { return }
    run-check 'go vet' go [vet ./...]
}

def lint-go-build [] {
    if not (go-project) { return }
    let target = if ('cmd' | path type) == dir { './cmd/...' } else { './...' }
    run-check 'go build' go [build -ldflags '-s -w' -o /dev/null $target]
}

def node-manager []: nothing -> string {
    if ('pnpm-lock.yaml' | path exists) {
        let package = open package.json
        let declaration = ($package.packageManager? | default '')
        let valid_declaration = (do { print $declaration | ^grep -Eq '^pnpm@[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$' } | complete)
        if (($declaration | describe) != string) or $valid_declaration.exit_code != 0 {
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
    if $manager == npm {
        run-check 'npm ci' npm [ci]
    } else {
        run-check 'pnpm install' pnpm [install --frozen-lockfile]
    }
}

def validate-node-version []: nothing -> nothing {
    let configured = ($env.QUALITY_GATE_NODE_VERSION? | default '')
    if not ('.node-version' | path exists) and ($configured | is-empty) {
        error make {msg: 'Missing .node-version for TypeScript typecheck. Add the Node.js major version used by the project.'}
    }
}

def typecheck-script []: nothing -> string {
    let command = (open package.json | get --optional scripts.typecheck | default '')
    if ($command | is-empty) {
        ''
    } else if not (['tsc' 'vue-tsc' 'nuxt'] | any {|binary| $command | str contains $binary }) {
        error make {msg: $"scripts.typecheck does not invoke a recognised type-checker binary (tsc, vue-tsc, nuxt). Got: \"($command)\"."}
    } else {
        $command
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
    } else if (package-has-dependency vue) or (glob --no-dir '**/*.vue' | is-not-empty) {
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
    let result = capture oxfmt [--list-different .]
    if $result.exit_code == 0 {
        print 'oxfmt: all files are correctly formatted.'
    } else {
        if ($result.stdout | is-not-empty) { print ($result.stdout | str trim) }
        if ($result.stderr | is-not-empty) { print -e ($result.stderr | str trim) }
        error make {msg: 'oxfmt found formatting differences; run `oxfmt --write .`'}
    }
}

def lint-typescript-oxlint [] {
    if not (node-project) { return }
    let paths = if (['.oxlintrc.json' '.oxlintrc.yaml' '.oxlintrc.yml' 'oxlint.config.js' 'oxlint.config.mjs' 'oxlint.config.ts'] | any {|file| $file | path exists}) {
        [.] 
    } else {
        [--config $env.QUALITY_GATE_OXLINT_CONFIG .]
    }
    let framework = typescript-framework
    let arguments = if $framework == next {
        [--react-plugin --nextjs-plugin --ignore-pattern '.next/**' --ignore-pattern 'out/**'] ++ $paths
    } else if (typescript-react-project) {
        [--react-plugin] ++ $paths
    } else {
        $paths
    }
    run-check 'oxlint' oxlint $arguments
}

def lint-typescript-react-doctor [] {
    if not (node-project) { return }
    if (typescript-react-project) {
        run-check 'react-doctor' react-doctor [.]
    } else {
        log info 'No React dependency found; skipping react-doctor.'
    }
}

def lint-typescript-typecheck [] {
    if not (node-project) { return }
    validate-node-version
    install-node-dependencies
    let manager = node-manager
    let runner = if $manager == npm { 'npm' } else { 'pnpm' }

    if (package-has-script typecheck) {
        typecheck-script | ignore
        let framework = typescript-framework
        if $framework == nuxt {
            if $manager == npm {
                run-check 'nuxt prepare' npm [exec --no -- nuxt prepare]
            } else {
                run-check 'nuxt prepare' pnpm [exec nuxt prepare]
            }
        }
        run-check 'TypeScript typecheck' $runner [run typecheck]
    } else if (package-contains 'vue') {
        run-check 'vue-tsc' $runner [exec vue-tsc --noEmit]
    } else if (package-contains 'nuxt') {
        if $manager == npm {
            run-check 'nuxt prepare' npm [exec --no -- nuxt prepare]
        } else {
            run-check 'nuxt prepare' pnpm [exec nuxt prepare]
        }
        run-check 'nuxt typecheck' $runner [exec nuxt typecheck]
    } else {
        run-check 'tsc' $runner [exec tsc --noEmit]
    }
}

def test-python [] {
    sync-python
    run-check 'uv pytest' uv [run pytest]
}

def test-go [] {
    run-check 'go test' go [test ./...]
}

def test-typescript [] {
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
            [lint go build]
        ]
        [lint typescript] => [
            [lint typescript oxlint]
            [lint typescript react-doctor]
        ]
        [strlint python] => [[lint python strlint]]
        [strlint go] => [[lint go strlint]]
        [strlint typescript] => [[lint typescript strlint]]
        [typecheck python] => [[lint python basedpyright]]
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
            [lint go build]
        ]
        'typescript' => [
            [format typescript oxfmt]
            [lint typescript oxlint]
            [lint typescript react-doctor]
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
        error make {msg: $"($title) failed: ($failure_count) of ($result_count) checks failed."}
    }
}

def run-language-category [category: string, language: string] {
    let normalized = normalize-language $language
    report-language-checks ($'($normalized) ($category)') $normalized (checks-for-category $category $normalized)
}

def check-fix [verb: string, language: string, check: string]: nothing -> string {
    match [$verb $language $check] {
        [format python ruff] => 'ruff format .'
        [lint python ruff] => 'ruff check .'
        [lint python complexipy] => 'complexipy .'
        [lint python basedpyright] => 'basedpyright'
        [lint python strlint] => 'ast-grep scan'
        [format go gofumpt] => 'gofumpt -w .'
        [format go goimports] => 'goimports -w .'
        [lint go golangci] => 'golangci-lint run'
        [lint go strlint] => 'ast-grep scan'
        [lint go vet] => 'go vet ./...'
        [lint go build] => 'go build ./...'
        [format typescript oxfmt] => 'oxfmt --write .'
        [lint typescript oxlint] => 'oxlint .'
        [lint typescript react-doctor] => 'react-doctor .'
        [lint typescript strlint] => 'ast-grep scan'
        [lint typescript typecheck] => 'npm run typecheck'
        [test python pytest] => 'uv run pytest'
        [test go test] => 'go test ./...'
        [test typescript test] => 'npm test'
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

def result-project [result: record, scope: string]: nothing -> string {
    let relative = ($result.project | path relative-to $scope)
    if ($relative | is-empty) or $relative == '.' { '.' } else { $relative }
}

def print-console-summary [title: string, scope: string, results: list<record>] {
    let failures = $results | where status == failure
    print ''
    print $'Quality Gate — ($title)'
    print $'Scope: ($scope)'
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
    let content = [
        $'# Quality Gate — ($title)'
        ''
        $'Scope: `($scope)`'
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
            let fix = xml-escape $result.fix
            $'    <testcase classname="(xml-escape $classname)" name="(xml-escape $name)">
      <failure message="($message)"><![CDATA[($message)

How to fix:
($fix)]]></failure>
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
        error make {msg: $"($title) failed: ($failure_count) of ($result_count) checks failed across ($project_count) projects."}
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
        error make {msg: $"Tests failed: ($failure_count) of ($result_count) test runners failed."}
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
        error make {msg: $"Quality gate failed: ($failure_count) of ($result_count) checks failed across ($directories | length) projects."}
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
        [lint go build] => (lint-go-build)
        [format typescript oxfmt] => (format-typescript)
        [lint typescript oxlint] => (lint-typescript-oxlint)
        [lint typescript react-doctor] => (lint-typescript-react-doctor)
        [lint typescript strlint] => (lint-strlint typescript $env.QUALITY_GATE_TYPESCRIPT_RULES)
        [lint typescript typecheck] => (lint-typescript-typecheck)
        [test python pytest] => (test-python)
        [test go test] => (test-go)
        [test typescript test] => (test-typescript)
        _ => (error make {msg: $'Unknown quality-gate check: ($verb) ($language) ($check)'})
    }
}

def main [verb?: string, language?: string, check?: string] {
    let shortcut = ($env.QUALITY_GATE_SHORTCUT? | default false)
    if $shortcut and (
        $verb == null
        or $language == null
        or $check != null
        or $verb not-in [format lint strlint typecheck tests]
    ) {
        print 'Usage: qg <format|lint|strlint|typecheck|tests> <py|python|go|ts|typescript>'
        exit 2
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

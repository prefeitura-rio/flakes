use std/assert
use std/testing *
use support/isolation.nu

const BUMP = path self | path dirname | path join .. release scripts compute-bump.sh

# ---------------------------------------------------------------------------
# compute-bump.sh
# ---------------------------------------------------------------------------

def commit [repository: path, message: string] {
    ^git -C $repository -c user.name=fixture -c user.email=fixture@example.invalid commit --quiet --allow-empty -m $message
}

def bump-repository []: nothing -> path {
    let repository = mktemp --directory | str trim
    ^git -C $repository init --quiet
    commit $repository 'chore: start'
    ^git -C $repository tag base
    $repository
}

def bump-of [repository: path, previous: string = 'base']: nothing -> string {
    let arguments = if ($previous | is-empty) { [] } else { [--previous-tag $previous] }
    ^bash $BUMP --repository $repository ...$arguments --target-sha HEAD | str trim
}

@test
def test-bump-is-patch-for-fixes-and-chores [] {
    let repository = bump-repository
    commit $repository 'fix: correct the exit code'
    commit $repository 'docs: explain the bake'
    let bump = bump-of $repository
    rm --recursive --force $repository
    assert equal $bump patch
}

@test
def test-bump-is-minor-for-a-feature [] {
    let repository = bump-repository
    commit $repository 'fix: a'
    commit $repository 'feat(engine): add a check'
    let bump = bump-of $repository
    rm --recursive --force $repository
    assert equal $bump minor
}

@test
def test-bump-is-major-for-a-breaking-change [] {
    let repository = bump-repository
    commit $repository 'feat: a'
    commit $repository 'refactor(engine)!: rename the checks'
    let bump = bump-of $repository
    let footer_repository = bump-repository
    commit $footer_repository "docs: x\n\nBREAKING CHANGE: the task names changed"
    let footer = bump-of $footer_repository
    rm --recursive --force $repository $footer_repository
    assert equal $bump major
    assert equal $footer major
}

@test
def test-bump-only-looks-after-the-previous-tag [] {
    let repository = bump-repository
    commit $repository 'feat!: an old breaking change'
    ^git -C $repository tag released
    commit $repository 'fix: after the release'
    let bump = bump-of $repository released
    rm --recursive --force $repository
    assert equal $bump patch
}

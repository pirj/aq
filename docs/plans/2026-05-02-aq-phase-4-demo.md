# Phase 4 — Demo: Rails 8 CI Side-by-Side Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a public Rails 8 demo repo (`pirj/aq-demo-rails`) showing two CI workflows on the same code: vanilla GitHub Actions (Ruby + Postgres + sequential rubocop/test/test:system) vs aq (snapshot of provisioned VM + parallel `aq fanout 3`). Publish measured wall-clock numbers in the README.

**Architecture:** Stock `rails new --database=postgresql` (Rails 8 defaults: tests included, Dockerfile generated, RuboCop omakase, Selenium system tests). Two CI workflows in `.github/workflows/`. The aq workflow caches the bootstrapped+provisioned snapshot keyed on `(Gemfile.lock, db/schema.rb, Dockerfile)` — on hit, restore is seconds; on miss, full provision then save. After restore, current source is rsync'd into the VM via `aq scp`, then `aq fanout 3` dispatches rubocop / `rails test` / `rails test:system` to three shards in parallel.

**Tech Stack:** Rails 8, Ruby 3.4, PostgreSQL 17, RuboCop omakase, Selenium with headless Chromium. aq for snapshot-based CI. GitHub Actions for both workflows.

**Reference:** No formal spec for Phase 4. The marketing context is in `docs/specs/2026-04-30-aq-ci-snapshots-design.md` ("Phase 4: Demo & content").

---

## Repo and Working Directory

The demo lives in a **separate** repo: `pirj/aq-demo-rails`. Throughout the plan, the working directory for tasks 1+ is `/Users/pirj/source/aq-demo-rails` (cloned in Task 0). The aq repo (`/Users/pirj/source/aq/cli`) is **untouched** by this plan.

---

## File Structure (in `aq-demo-rails`)

| File | Status | Responsibility |
|------|--------|----------------|
| `Gemfile`, `config/`, `app/`, `db/`, `test/` | Generated | Stock `rails new` output, then scaffolded `Post`/`Comment` resources to give tests + migrations real work to do. |
| `Dockerfile` | Generated | Used as the canonical reference for what the VM needs; not directly built in CI. |
| `db/seeds.rb` | Modify | Seed ~50 posts × 3 comments so `db:seed` is non-trivial. |
| `bin/aq-provision` | Create | Runs inside the Alpine VM on first cold start: `apk add ruby ruby-dev build-base postgresql postgresql-client postgresql-contrib chromium chromium-chromedriver`, init+start postgres, `bundle install`, `bin/rails db:create db:migrate db:seed`. Idempotent. |
| `.github/workflows/ci-vanilla.yml` | Create | Standard Rails CI. Ruby setup-ruby, services postgres, sequential rubocop / `rails test` / `rails test:system`. |
| `.github/workflows/ci-aq.yml` | Create | aq workflow. Cache lookup → restore-or-provision-then-save → scp current source → `aq fanout 3 -- '...'`. |
| `README.md` | Create | What this demo is, side-by-side workflow links, measured numbers table, link back to `pirj/aq`. |

---

## Task 0: Repo + branch setup

**Files:** none in source — operational.

- [ ] **Step 1: Create the GitHub repo**

```bash
gh repo create pirj/aq-demo-rails --public \
  --description "Rails 8 demo: vanilla GitHub Actions CI vs aq snapshots + fan-out, side by side." \
  --homepage "https://github.com/pirj/aq" \
  --clone --add-readme
cd ~/source/aq-demo-rails 2>/dev/null || mv aq-demo-rails ~/source/ && cd ~/source/aq-demo-rails
```

Confirm `git remote -v` shows `git@github.com:pirj/aq-demo-rails.git`.

- [ ] **Step 2: Verify Ruby toolchain**

Run: `mise install ruby@latest && mise use ruby@latest`
Expected: a working Ruby 3.4+ in `mise current ruby`. If `mise` not available, `rbenv install 3.4 && rbenv local 3.4` or `asdf install ruby 3.4`.

```bash
ruby -v
gem install rails
rails -v
```

Expected: `Rails 8.0.x`.

- [ ] **Step 3: Verify Postgres locally for `rails new` checks**

```bash
brew services start postgresql@17 || brew install postgresql@17 && brew services start postgresql@17
psql -lqt | head -3
```

Expected: postgres responds. (Rails 8 will use it for the dev DB locally during scaffolding sanity checks.)

---

## Task 1: Generate the Rails app

- [ ] **Step 1: Run `rails new` into the empty repo**

```bash
cd ~/source/aq-demo-rails
# rails new wants an empty dir or --force. The repo has only README.md from --add-readme.
rails new . --database=postgresql --force
```

- [ ] **Step 2: Verify generated artefacts**

```bash
ls Dockerfile bin/docker-entrypoint config/database.yml test/test_helper.rb test/application_system_test_case.rb .rubocop.yml
```

All six files must exist. If any is missing, your Rails version is older than 8; bump it before continuing.

- [ ] **Step 3: Local sanity check — db setup + tests pass on a freshly-generated app**

```bash
bin/rails db:create db:migrate
bin/rubocop --no-color
bin/rails test
bin/rails test:system 2>&1 | tail -5
```

Expected: rubocop reports 0 offenses; tests pass (the freshly-generated app has trivial generated tests). System tests need a Chrome/Chromium binary on PATH — install with `brew install --cask google-chrome` if not already there.

- [ ] **Step 4: Commit baseline**

```bash
git add -A
git commit -m "rails new --database=postgresql"
git push
```

---

## Task 2: Scaffold Posts + Comments + a real-feeling system test

We need the test suite to do enough work that wall-clock differences are visible.

- [ ] **Step 1: Generate scaffolds**

```bash
bin/rails g scaffold Post title:string body:text
bin/rails g scaffold Comment post:references body:text
bin/rails db:migrate
```

- [ ] **Step 2: Add `has_many` association**

Edit `app/models/post.rb`:

Old:
```ruby
class Post < ApplicationRecord
end
```

New:
```ruby
class Post < ApplicationRecord
  has_many :comments, dependent: :destroy
end
```

- [ ] **Step 3: Add a non-trivial system test**

Replace `test/system/posts_test.rb` with:

```ruby
require "application_system_test_case"

class PostsTest < ApplicationSystemTestCase
  setup do
    @post = posts(:one)
  end

  test "visiting the index" do
    visit posts_url
    assert_selector "h1", text: "Posts"
  end

  test "creating a Post" do
    visit posts_url
    click_on "New post"

    fill_in "Body", with: "demo body"
    fill_in "Title", with: "demo title"
    click_on "Create Post"

    assert_text "Post was successfully created"
  end

  test "destroying a Post" do
    visit post_url(@post)
    accept_confirm { click_on "Destroy this post" }
    assert_text "Post was successfully destroyed"
  end
end
```

- [ ] **Step 4: Add fixture content**

Edit `test/fixtures/posts.yml`:

```yaml
one:
  title: First post
  body: Body of the first post.

two:
  title: Second post
  body: Body of the second post.
```

Edit `test/fixtures/comments.yml`:

```yaml
one:
  post: one
  body: First comment on the first post.

two:
  post: one
  body: Second comment on the first post.
```

- [ ] **Step 5: Add a meaningful seed**

Edit `db/seeds.rb`, replacing the file:

```ruby
# Seed enough records that db:seed has measurable wall clock.
50.times do |i|
  post = Post.create!(title: "Post #{i}", body: "Body of post #{i}. " * 20)
  3.times do |j|
    Comment.create!(post: post, body: "Comment #{j} on post #{i}.")
  end
end
puts "Seeded #{Post.count} posts and #{Comment.count} comments."
```

- [ ] **Step 6: Verify everything still passes**

```bash
bin/rails db:reset   # drops, recreates, loads schema, runs seeds
bin/rubocop
bin/rails test
bin/rails test:system
```

Expected: all green. ~5-10 unit/controller tests, 3 system tests, rubocop clean.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "Add Post + Comment scaffolds, system tests, and seed data"
git push
```

---

## Task 3: Vanilla CI workflow

The baseline. Standard Rails CI patterns.

- [ ] **Step 1: Create `.github/workflows/ci-vanilla.yml`**

```yaml
name: CI (vanilla)

on:
  push:
  pull_request:

jobs:
  vanilla:
    runs-on: ubuntu-latest
    timeout-minutes: 15

    services:
      postgres:
        image: postgres:17
        env:
          POSTGRES_PASSWORD: postgres
        ports:
          - 5432:5432
        options: >-
          --health-cmd "pg_isready -U postgres"
          --health-interval 5s
          --health-timeout 5s
          --health-retries 10

    env:
      RAILS_ENV: test
      DATABASE_URL: postgres://postgres:postgres@localhost:5432

    steps:
      - uses: actions/checkout@v4

      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true

      - name: Install Chromium for system tests
        run: |
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends chromium-browser
          chromium-browser --version || google-chrome --version || true

      - name: Prepare DB
        run: bin/rails db:create db:schema:load

      - name: Rubocop
        run: bin/rubocop

      - name: Minitest
        run: bin/rails test

      - name: System tests
        run: bin/rails test:system
```

- [ ] **Step 2: Push and iterate to green**

```bash
git add .github/workflows/ci-vanilla.yml
git commit -m "Add vanilla CI workflow"
git push
gh run watch
```

Expected categories of issues:
- **Chrome binary on PATH**: Rails 8's `application_system_test_case.rb` may name the driver differently (`:selenium_chrome_headless` is standard). If chromium-browser doesn't satisfy, install `google-chrome-stable` from the official .deb instead.
- **Postgres role/db missing**: `db:create` may fail if `DATABASE_URL` doesn't grant CREATE. Use `pg_isready` then `bin/rails db:create` with `RAILS_ENV=test`.
- **Selenium driver mismatch**: Rails 8 ships `selenium-webdriver`. If chromedriver isn't bundled, install `chromedriver` package.

Iterate: edit the workflow, commit, push, re-watch. Stop only when the run is green.

- [ ] **Step 3: Record baseline timings**

Re-run the workflow 3 times via `gh workflow run "CI (vanilla)" --ref main` (or empty commits) and collect wall-clock from `gh run list --workflow="CI (vanilla)" --limit 5 --json databaseId,createdAt,updatedAt`. Save median into a scratch note for the README later.

---

## Task 4: AQ provisioning script

Lives inside the demo repo. Runs **inside the Alpine VM** to install ruby, postgres, chromium, then `bundle install`, `db:create`, `db:migrate`. The aq workflow runs this once to build the snapshot.

- [ ] **Step 1: Create `bin/aq-provision`**

```bash
#!/usr/bin/env sh
# Runs inside the Alpine VM. Provisions everything needed to run the test
# suite. Idempotent — re-running on an already-provisioned VM is a no-op.
set -eu

APK_PACKAGES="ruby ruby-dev ruby-bundler build-base \
  postgresql17 postgresql17-client postgresql17-contrib \
  chromium chromium-chromedriver \
  git tzdata yaml-dev"

echo "[provision] apk update + install"
apk update
apk add --no-cache $APK_PACKAGES

echo "[provision] init postgres data dir"
PGDATA=/var/lib/postgresql/17/data
if [ ! -d "$PGDATA" ]; then
  mkdir -p "$PGDATA"
  chown -R postgres:postgres "$PGDATA"
  su postgres -c "initdb --locale=C.UTF-8 --encoding=UTF8 -D '$PGDATA'"
fi

echo "[provision] start postgres"
rc-service postgresql start || su postgres -c "pg_ctl -D '$PGDATA' -l /tmp/pglog start"

echo "[provision] create rails db role"
su postgres -c "psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='rails'\"" | grep -q 1 \
  || su postgres -c "psql -c \"CREATE ROLE rails WITH LOGIN SUPERUSER PASSWORD 'rails';\""

echo "[provision] bundle install"
cd /repo
bundle config set --local path 'vendor/bundle'
bundle install --jobs=4 --retry=3

echo "[provision] db:create + db:migrate (test env)"
DATABASE_URL=postgres://rails:rails@localhost:5432 RAILS_ENV=test bin/rails db:create db:migrate
DATABASE_URL=postgres://rails:rails@localhost:5432 RAILS_ENV=development bin/rails db:create db:migrate

echo "[provision] DONE"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x bin/aq-provision
git add bin/aq-provision
git commit -m "Add bin/aq-provision for one-shot aq snapshot setup"
git push
```

---

## Task 5: AQ CI workflow

Caches the post-provision snapshot keyed on `(Gemfile.lock, db/schema.rb, Dockerfile, bin/aq-provision)`. On hit: restore. On miss: bootstrap+scp+provision+snapshot+save. Then `aq scp` current source over the snapshot's `/repo`, then `aq fanout 3 -- ...`.

- [ ] **Step 1: Create `.github/workflows/ci-aq.yml`**

```yaml
name: CI (aq)

on:
  push:
  pull_request:

jobs:
  aq:
    runs-on: ubuntu-latest
    timeout-minutes: 20

    steps:
      - uses: actions/checkout@v4

      - name: Enable KVM
        run: |
          ls -l /dev/kvm
          sudo chmod 666 /dev/kvm

      - name: Install qemu/socat/ovmf
        run: |
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends \
            qemu-system-x86 qemu-utils socat ovmf wget gpg ca-certificates coreutils \
            meson ninja-build pkg-config liblua5.4-dev libinih-dev libglib2.0-dev \
            git build-essential

      - name: Cache aq + tio binaries
        id: aq-cache
        uses: actions/cache@v4
        with:
          path: |
            /usr/local/bin/aq
            /usr/local/bin/tio
          key: aq-2.3.0-tio-3.9-${{ runner.os }}

      - name: Install aq + tio if cache miss
        if: steps.aq-cache.outputs.cache-hit != 'true'
        run: |
          curl -sL https://raw.githubusercontent.com/pirj/aq/v2.3.0/aq -o /tmp/aq
          chmod +x /tmp/aq
          sudo mv /tmp/aq /usr/local/bin/aq
          aq --version
          git clone --depth 1 --branch v3.9 https://github.com/tio/tio.git /tmp/tio
          cd /tmp/tio && meson setup build && meson compile -C build && sudo meson install -C build

      - name: Add SSH key
        run: |
          mkdir -p ~/.ssh
          ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
          chmod 600 ~/.ssh/id_ed25519

      - name: Compute snapshot key
        id: key
        run: |
          KEY=$(sha256sum Gemfile.lock db/schema.rb Dockerfile bin/aq-provision \
                | awk '{print $1}' | sha256sum | head -c 16)
          echo "snapkey=$KEY" >> "$GITHUB_OUTPUT"
          echo "Snapshot key: $KEY"

      - name: Cache aq snapshot
        id: snap-cache
        uses: actions/cache@v4
        with:
          path: ~/.local/share/aq/snapshots/x86_64/provisioned
          key: aq-snapshot-${{ steps.key.outputs.snapkey }}

      - name: Cache aq base image (alpine bootstrap is slow)
        uses: actions/cache@v4
        with:
          path: ~/.local/share/aq/x86_64
          key: aq-alpine-base-3.22.2

      - name: Provision snapshot if cache miss
        if: steps.snap-cache.outputs.cache-hit != 'true'
        run: |
          set -ex
          aq new app
          aq start app
          aq scp -r . app:/repo
          aq exec app /repo/bin/aq-provision
          aq stop app
          aq snapshot create app provisioned
          aq rm app

      - name: Run rubocop / minitest / system tests in parallel via aq fanout
        run: |
          # Materialise the snapshot if cache hit (skips provision step above).
          # Code may have changed since the snapshot — push current source over
          # the snapshot's /repo before fanning out.
          aq new --from-snapshot=provisioned staging
          aq start staging
          aq scp -r . staging:/repo
          aq stop staging
          # Re-snapshot with current code so all 3 fanout shards see it.
          # (Cheap: only the /repo delta is in the new layer.)
          aq snapshot create staging running-with-code
          aq rm staging

          aq fanout running-with-code 3 -- '
            cd /repo
            export DATABASE_URL=postgres://rails:rails@localhost:5432
            rc-service postgresql start || pg_ctl -D /var/lib/postgresql/17/data start
            case $AQ_SHARD_INDEX in
              0) bundle exec rubocop ;;
              1) RAILS_ENV=test bin/rails test ;;
              2) RAILS_ENV=test bin/rails test:system ;;
            esac
          '

      - name: Cleanup ephemeral snapshot
        if: always()
        run: aq snapshot rm --force running-with-code 2>/dev/null || true
```

- [ ] **Step 2: Push and iterate to green**

```bash
git add .github/workflows/ci-aq.yml
git commit -m "Add aq CI workflow with snapshot cache and 3-shard fanout"
git push
gh run watch
```

Expected categories of issues (matches Phase 1 experience plus new):
- **Snapshot cache key collisions**: be sure `Gemfile.lock` is checked in (it should be after `rails new`).
- **chromium driver path inside Alpine**: the Alpine `chromium` package's binary is `chromium-browser`. Rails 8's Selenium driver may need `Selenium::WebDriver::Chrome::Service.driver_path` set. If system tests fail with "chromedriver not found", set `CHROME_BIN=/usr/bin/chromium-browser` and `WEBDRIVER_CHROMEDRIVER_PATH=/usr/bin/chromedriver` in the shard's env.
- **postgres bound to localhost only**: aq's user-mode networking already loops localhost back into the guest. Should just work.
- **`aq exec` shell quoting on multi-line case statement**: the heredoc-style multi-line argument may need single quotes throughout. Test interactively first if iteration burns too many CI minutes.

Iterate. Stop when green.

- [ ] **Step 3: Confirm a warm run uses the cache**

After the first successful run, push an empty commit (`git commit --allow-empty -m "trigger warm run"; git push`). The next run should:
- Skip "Provision snapshot if cache miss" (cache hit on snapkey)
- Reach "Run rubocop / minitest / system tests" within ~30-60s of job start

If it doesn't, the snapshot dir didn't get populated correctly — debug `actions/cache` paths.

---

## Task 6: Measure cold + warm timings

We want a defensible table for the README. Five runs of each variant, take median.

- [ ] **Step 1: Reset both caches to force cold starts**

In the GitHub UI or via `gh extension install actions/gh-actions-cache && gh actions-cache delete <key>`, delete:
- `aq-snapshot-*`
- `aq-alpine-base-*`

The vanilla workflow's only cache (bundler) can stay — that's the realistic warm-warm comparison anyway.

- [ ] **Step 2: Trigger 5 cold runs of each (alternating)**

```bash
for i in 1 2 3 4 5; do
  gh workflow run "CI (aq)" --ref main
  gh workflow run "CI (vanilla)" --ref main
  sleep 30
done
```

After all complete, dump timing JSON:

```bash
gh run list --workflow="CI (aq)" --limit 10 --json databaseId,name,createdAt,updatedAt,conclusion > /tmp/aq-runs.json
gh run list --workflow="CI (vanilla)" --limit 10 --json databaseId,name,createdAt,updatedAt,conclusion > /tmp/vanilla-runs.json
```

- [ ] **Step 3: Compute medians**

Wall clock per run = updatedAt - createdAt. Use any tool you like; an awk one-liner suffices. Record:
- vanilla median
- aq cold median (first run, snapshot miss)
- aq warm median (subsequent runs, snapshot hit)

Plus a one-line interpretation sentence per number.

---

## Task 7: README and badges

- [ ] **Step 1: Replace `README.md`**

```markdown
# aq-demo-rails

A stock Rails 8 application showing two CI workflows side by side: vanilla GitHub Actions vs [aq](https://github.com/pirj/aq) snapshots + 3-shard fan-out.

## What's in the suite

- ~10 minitest unit / controller tests
- 3 Capybara/Selenium system tests
- RuboCop omakase
- A Postgres-backed schema with two tables (`posts`, `comments`) and 50 seeded posts × 3 comments each

## CI variants

- [![CI (vanilla)](https://github.com/pirj/aq-demo-rails/actions/workflows/ci-vanilla.yml/badge.svg)](https://github.com/pirj/aq-demo-rails/actions/workflows/ci-vanilla.yml) — `setup-ruby` with bundler-cache, `services: postgres:17`, sequential `bin/rubocop` → `bin/rails test` → `bin/rails test:system`.
- [![CI (aq)](https://github.com/pirj/aq-demo-rails/actions/workflows/ci-aq.yml/badge.svg)](https://github.com/pirj/aq-demo-rails/actions/workflows/ci-aq.yml) — aq snapshot of an Alpine VM with bundle, postgres, chromium pre-installed and migrations applied. `aq fanout 3` runs rubocop / `rails test` / `rails test:system` in three parallel shards.

## Measured timings

Wall-clock medians of 5 GitHub Actions runs each, on `ubuntu-latest`:

| Workflow                   | First run (cold) | Subsequent runs (warm) |
|---------------------------|------------------|------------------------|
| Vanilla (sequential)      | <FILL_VANILLA_COLD>            | <FILL_VANILLA_WARM>             |
| aq (snapshot + fanout 3)  | <FILL_AQ_COLD>            | <FILL_AQ_WARM>             |

The cold-start aq run is one-time per `(Gemfile.lock, db/schema.rb, Dockerfile, bin/aq-provision)` tuple. As long as none of those four files change, every subsequent commit hits the cache and runs in `<FILL_AQ_WARM>`. The vanilla workflow has no equivalent — it always re-runs `bundle install` (cached) + `db:schema:load` (not cached).

## Try it

```sh
# install aq from https://github.com/pirj/aq
brew install qemu tio socat
git clone https://github.com/pirj/aq && export PATH=$PWD/aq:$PATH

# clone this demo
git clone https://github.com/pirj/aq-demo-rails && cd aq-demo-rails

# build the snapshot once
aq new app
aq start app
aq scp -r . app:/repo
aq exec app /repo/bin/aq-provision
aq stop app
aq snapshot create app provisioned
aq rm app

# every subsequent test run is fast
aq fanout provisioned 3 -- '
  cd /repo
  case $AQ_SHARD_INDEX in
    0) bundle exec rubocop ;;
    1) RAILS_ENV=test bin/rails test ;;
    2) RAILS_ENV=test bin/rails test:system ;;
  esac
'
```

## License

MIT.
```

Replace `<FILL_…>` placeholders with the median values from Task 6. Keep them human-readable: `2m 14s`, `48s`, etc.

- [ ] **Step 2: Commit and push**

```bash
git add README.md
git commit -m "README: side-by-side CI comparison with measured numbers"
git push
```

- [ ] **Step 3: Smoke-check the badges render**

Open https://github.com/pirj/aq-demo-rails — both badges should show green. The README table is the headline of the demo.

---

## Self-Review Checklist

- **Coverage:**
  - Stock Rails 8 app with default tests → Tasks 1, 2 ✓
  - Two CI workflows side by side → Tasks 3, 5 ✓
  - 3 shards via `aq fanout` (rubocop, `rails test`, `rails test:system`) → Task 5 step 1 ✓
  - Bundle install + migrations baked into snapshot → Task 4 (`bin/aq-provision`) + Task 5's "Provision snapshot if cache miss" step ✓
  - Measured timings in README → Tasks 6, 7 ✓
  - Separate repo → Task 0 ✓
- **Placeholder scan:** the README has `<FILL_…>` placeholders deliberately, replaced with real numbers in Task 7 step 1. Every other code block is concrete.
- **Type / name consistency:** `provisioned` and `running-with-code` snapshot tags are used consistently in Task 5. `bin/aq-provision` filename consistent across Tasks 4, 5, 7.

## Out of Scope (post-launch tweaks)

- Blogpost on Hacker News / Lobsters / r/devops with the numbers — separate effort once the repo's numbers stabilise.
- Comparison with other CI orchestration tools (Earthly, Dagger, Nixery). Speculative.
- aq install via Homebrew formula (currently the readme uses raw curl from a release). Tracked in aq's own roadmap.
- Animated GIF / asciinema recording of the side-by-side runs. Nice-to-have for the blogpost, not blocking the demo repo.
- Extending to a multi-repo monorepo demo (Sidekiq + Action Mailer + Active Storage). Phase 5+ if the demo gains traction.

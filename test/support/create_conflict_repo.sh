#!/usr/bin/env bash
#
# Creates a bare git repo with scripted conflict scenarios for testing
# the ConflictResolver module.
#
# Outputs:
#   BARE_REPO=/tmp/conflict-test-bare-XXXX
#   WORKSPACE=/tmp/conflict-test-workspace-XXXX
#
# Branches created:
#   staging          - base branch with initial files
#   deploy-YYYYMMDD  - deploy branch with a change (simulates earlier merged PR)
#   feature-conflict - changes same lines as deploy branch (conflict)
#   feature-clean    - changes different file (no conflict)
#   feature-binary-conflict - binary file conflict (tests bailout)

set -euo pipefail

DATE=$(date +%Y%m%d)
BARE_REPO=$(mktemp -d /tmp/conflict-test-bare-XXXXXX)
WORKSPACE=$(mktemp -d /tmp/conflict-test-workspace-XXXXXX)
SETUP_DIR=$(mktemp -d /tmp/conflict-test-setup-XXXXXX)

# Initialize bare repo
git init --bare "$BARE_REPO" > /dev/null 2>&1

# Clone for setup
git clone "$BARE_REPO" "$SETUP_DIR" > /dev/null 2>&1
cd "$SETUP_DIR"

git config user.email "test@example.com"
git config user.name "Test"

# Create staging branch with base files
cat > lib/app.ex << 'ELIXIR'
defmodule App do
  @moduledoc "Main application module"

  def hello do
    :world
  end

  def version do
    "1.0.0"
  end
end
ELIXIR

cat > lib/helper.ex << 'ELIXIR'
defmodule Helper do
  def format(value) do
    inspect(value)
  end
end
ELIXIR

mkdir -p assets
echo "body { color: black; }" > assets/style.css

git add -A
git commit -m "Initial commit" > /dev/null
git branch -M staging
git push origin staging > /dev/null 2>&1

# Create deploy branch (simulates an earlier merged PR changing the same area)
git checkout -b "deploy-$DATE" > /dev/null 2>&1

cat > lib/app.ex << 'ELIXIR'
defmodule App do
  @moduledoc "Main application module"

  def hello do
    :deploy_world
  end

  def version do
    "1.1.0"
  end

  def deployed_at do
    DateTime.utc_now()
  end
end
ELIXIR

git add -A
git commit -m "Deploy branch changes" > /dev/null
git push origin "deploy-$DATE" > /dev/null 2>&1

# Create feature-conflict branch (off staging, changes same lines)
git checkout staging > /dev/null 2>&1
git checkout -b feature-conflict > /dev/null 2>&1

cat > lib/app.ex << 'ELIXIR'
defmodule App do
  @moduledoc "Main application module - updated"

  def hello do
    :feature_world
  end

  def version do
    "1.2.0"
  end

  def greet(name) do
    "Hello, #{name}!"
  end
end
ELIXIR

git add -A
git commit -m "Feature branch changes" > /dev/null
git push origin feature-conflict > /dev/null 2>&1

# Create feature-clean branch (off staging, changes different file)
git checkout staging > /dev/null 2>&1
git checkout -b feature-clean > /dev/null 2>&1

cat > lib/new_module.ex << 'ELIXIR'
defmodule NewModule do
  def new_function do
    :ok
  end
end
ELIXIR

git add -A
git commit -m "Add new module (no conflict)" > /dev/null
git push origin feature-clean > /dev/null 2>&1

# Create feature-binary-conflict branch (off staging, binary file conflict)
git checkout staging > /dev/null 2>&1
git checkout -b feature-binary-staging > /dev/null 2>&1

# Create a binary file on staging side
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR-staging' > assets/logo.png
git add -A
git commit -m "Add logo on staging side" > /dev/null
git push origin feature-binary-staging > /dev/null 2>&1

# Now create the deploy branch version of the binary
git checkout "deploy-$DATE" > /dev/null 2>&1
git merge feature-binary-staging > /dev/null 2>&1
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR-deploy' > assets/logo.png
git add -A
git commit -m "Modify logo on deploy branch" > /dev/null
git push origin "deploy-$DATE" --force > /dev/null 2>&1

# Create the conflicting binary PR branch
git checkout staging > /dev/null 2>&1
git checkout -b feature-binary-conflict > /dev/null 2>&1
git merge feature-binary-staging > /dev/null 2>&1
printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR-feature' > assets/logo.png
git add -A
git commit -m "Modify logo on feature branch" > /dev/null
git push origin feature-binary-conflict > /dev/null 2>&1

# Clone workspace for the ConflictResolver to use
git clone "$BARE_REPO" "$WORKSPACE" > /dev/null 2>&1
cd "$WORKSPACE"
git config user.email "test@example.com"
git config user.name "Test"
git checkout "deploy-$DATE" > /dev/null 2>&1

# Clean up setup dir
rm -rf "$SETUP_DIR"

echo "BARE_REPO=$BARE_REPO"
echo "WORKSPACE=$WORKSPACE"
echo "DEPLOY_BRANCH=deploy-$DATE"

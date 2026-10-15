#!/usr/bin/env bash
# Runs inside a ruby container: Sidekiq's own minitest suite against a server.
#
#   sidekiq_suite.sh <redis-url> <label> [test files...]
#
# /src/sidekiq is the checkout (fetch_suites.sh). The suite reads REDIS_URL
# (test/helper.rb) and FLUSHDBs it before most tests: do not point it at a
# server holding anything you want. Output: /out/sidekiq-<label>.log
set -uo pipefail
URL=${1:?redis url}
LABEL=${2:?label}
shift 2
cd /src/sidekiq
export BUNDLE_WITHOUT="development:load_test" BUNDLE_PATH=/src/sidekiq-bundle RAILS_VERSION=${RAILS_VERSION:-8.1}
if ! bundle check > /dev/null 2>&1; then
  bundle install -j4 > /out/sidekiq-install.log 2>&1 || { echo "bundle install failed"; tail -30 /out/sidekiq-install.log; exit 1; }
fi
export REDIS_URL=$URL
if [ $# -eq 0 ]; then
  set -- test/*_test.rb test/iterable/*_test.rb
fi
# One process for all files (as `rake test` does), verbose so every test's
# result is listed.
timeout 3600 bundle exec ruby -w -Ilib -Itest -e 'files = ARGV.take_while { |a| a != "--" }; ARGV.replace(ARGV.drop(files.size + 1)); files.each { |f| require File.expand_path(f) }' "$@" -- -v \
  > /out/sidekiq-$LABEL.log 2>&1 < /dev/null
echo "exit=$?"
grep -E '^[0-9]+ runs' /out/sidekiq-$LABEL.log

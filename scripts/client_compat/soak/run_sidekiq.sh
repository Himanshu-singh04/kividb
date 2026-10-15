#!/usr/bin/env bash
# Inside a ruby container: install the Sidekiq soak's gems (cached on /src)
# and run it. Environment is passed through to soak.rb.
set -euo pipefail
W=/src/soak-sidekiq
mkdir -p "$W"
cp /h/soak/sidekiq/soak.rb /h/soak/sidekiq/Gemfile "$W/"
cd "$W"
export BUNDLE_PATH=/src/soak-sidekiq-bundle BUNDLE_GEMFILE=$W/Gemfile
bundle check > /dev/null 2>&1 || bundle install -j4 > /dev/null
exec bundle exec ruby soak.rb

# End-to-end soak for Sidekiq against a Redis-compatible server.
#
#   REDIS_URL=redis://host:6379/0 N=5000 bundle exec ruby soak.rb
#
# One process pushes the jobs and runs an embedded Sidekiq (configure_embed).
# Workload: N jobs, ~15% scheduled 0-3 s ahead (perform_in), ~15% failing
# their first one or two attempts and retried after 1 s (sidekiq_retry_in),
# plus BATCH_PUSH jobs pushed with push_bulk. Sidekiq talks RESP3 (HELLO 3)
# through redis-client.
#
# Checks: every job succeeded exactly once, none died, and the queue, the
# schedule, retry and dead sets are empty at the end.
# Progress goes to PROGRESS_FILE (if set) for an outside restart script.
# ALLOW_REEXEC=1 tolerates jobs run twice (at-least-once after a crash).
require "sidekiq"
require "sidekiq/api"

URL = ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0")
N = Integer(ENV.fetch("N", "5000"))
TIMEOUT = Integer(ENV.fetch("TIMEOUT_S", "300"))
QUEUE = ENV.fetch("QUEUE", "soak#{Time.now.to_i}")
PROGRESS_FILE = ENV["PROGRESS_FILE"]

LOCK = Mutex.new
SUCCESSES = Hash.new(0)
EXECUTIONS = Hash.new(0)

class SoakJob
  include Sidekiq::Job
  sidekiq_options retry: 5
  sidekiq_retry_in { |_count, _exc| 1 }

  def perform(key, fail_times)
    n = LOCK.synchronize { EXECUTIONS[key] += 1 }
    raise "planned failure #{n}/#{fail_times}" if n <= fail_times
    LOCK.synchronize { SUCCESSES[key] += 1 }
  end
end

Sidekiq.configure_client { |c| c.redis = {url: URL} }
Sidekiq.default_configuration.logger.level = Logger::WARN

instance = Sidekiq.configure_embed do |config|
  config.redis = {url: URL}
  config.queues = [QUEUE]
  config.concurrency = Integer(ENV.fetch("CONCURRENCY", "10"))
  config[:average_scheduled_poll_interval] = 1
  config.logger.level = Logger::WARN
end

# A push that meets a server that is down (or still loading) is retried.
# Sidekiq pushes are not idempotent, so a retried push whose first attempt did
# get through shows up as a duplicate (tolerated only with ALLOW_REEXEC=1).
def with_retry
  attempts = 0
  begin
    yield
  rescue RedisClient::ConnectionError, RedisClient::CommandError => e
    attempts += 1
    raise if attempts > 60
    puts "retrying push after: #{e.class}: #{e.message}"
    sleep 0.5
    retry
  end
end

t0 = Time.now
rng = Random.new(12345)
keys = []
bulk = []
N.times do |i|
  key = "job:#{i}"
  keys << key
  r = rng.rand
  if r < 0.15
    delay = rng.rand * 3
    with_retry { SoakJob.set(queue: QUEUE).perform_in(delay, key, 0) }
  elsif r < 0.30
    with_retry { SoakJob.set(queue: QUEUE).perform_async(key, 1 + (i % 2)) }
  elsif r < 0.50
    bulk << [key, 0]
  else
    with_retry { SoakJob.set(queue: QUEUE).perform_async(key, 0) }
  end
end
bulk.each_slice(500) { |s| with_retry { Sidekiq::Client.push_bulk("class" => SoakJob, "queue" => QUEUE, "args" => s) } }
puts "queued #{N} jobs in #{((Time.now - t0) * 1000).round} ms"

instance.run
last = -1
loop do
  done = LOCK.synchronize { keys.count { |k| SUCCESSES[k] > 0 } }
  if PROGRESS_FILE && done != last
    File.write(PROGRESS_FILE, "#{done} #{N}\n") rescue nil
    last = done
  end
  break if done >= N || Time.now - t0 > TIMEOUT
  sleep 0.2
end
elapsed = ((Time.now - t0) * 1000).round
sleep 3
instance.stop

problems = []
missing = keys.select { |k| SUCCESSES[k] == 0 }
dup = keys.select { |k| SUCCESSES[k] > 1 }
problems << "#{missing.size} jobs never succeeded, e.g. #{missing.first(5).join(", ")}" if missing.any?
if dup.any?
  msg = "#{dup.size} jobs succeeded more than once, e.g. #{dup.first(5).join(", ")}"
  if ENV["ALLOW_REEXEC"] == "1"
    puts "note: #{msg} (allowed: at-least-once after a crash)"
  else
    problems << msg
  end
end

q = Sidekiq::Queue.new(QUEUE)
sizes = {
  enqueued: q.size,
  scheduled: Sidekiq::ScheduledSet.new.count { |j| j.queue == QUEUE },
  retry: Sidekiq::RetrySet.new.count { |j| j.queue == QUEUE },
  dead: Sidekiq::DeadSet.new.count { |j| j.queue == QUEUE }
}
nonzero = sizes.select { |_, v| v > 0 }
problems << "not empty at the end: #{nonzero}" if nonzero.any?
leftover = Sidekiq.redis { |c| c.call("EXISTS", "queue:#{QUEUE}") }
problems << "queue:#{QUEUE} key still exists" if leftover.to_i > 0

summary = {queue: QUEUE, jobs: N, elapsed_ms: elapsed, succeeded_once: N - missing.size - dup.size,
           missing: missing.size, duplicated: dup.size, **sizes, ok: problems.empty?}
puts summary.to_json
problems.each { |p| puts "FAIL: #{p}" }
exit(problems.empty? ? 0 : 1)

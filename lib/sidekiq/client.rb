# frozen_string_literal: true

require "securerandom"
require "sidekiq/middleware/chain"

module Sidekiq
  class Client
    ##
    # Define client-side middleware:
    #
    #   client = Sidekiq::Client.new
    #   client.middleware do |chain|
    #     chain.use MyClientMiddleware
    #   end
    #   client.push('class' => 'SomeWorker', 'args' => [1,2,3])
    #
    # All client instances default to the globally-defined
    # Sidekiq.client_middleware but you can change as necessary.
    #
    def middleware(&block)
      @chain ||= Sidekiq.client_middleware
      if block
        @chain = @chain.dup
        yield @chain
      end
      @chain
    end

    attr_accessor :redis_pool

    # Sidekiq::Client normally uses the default Redis pool but you may
    # pass a custom ConnectionPool if you want to shard your
    # Sidekiq jobs across several Redis instances (for scalability
    # reasons, e.g.)
    #
    #   Sidekiq::Client.new(ConnectionPool.new { Redis.new })
    #
    # Generally this is only needed for very large Sidekiq installs processing
    # thousands of jobs per second.  I don't recommend sharding unless you
    # cannot scale any other way (e.g. splitting your app into smaller apps).
    def initialize(redis_pool = nil)
      @redis_pool = redis_pool || Thread.current[:sidekiq_via_pool] || Sidekiq.redis_pool
    end

    ##
    # The main method used to push a job to Redis.  Accepts a number of options:
    #
    #   queue - the named queue to use, default 'default'
    #   class - the worker class to call, required
    #   args - an array of simple arguments to the perform method, must be JSON-serializable
    #   at - timestamp to schedule the job (optional), must be Numeric (e.g. Time.now.to_f)
    #   retry - whether to retry this job if it fails, default true or an integer number of retries
    #   backtrace - whether to save any error backtrace, default false
    #
    # If class is set to the class name, the jobs' options will be based on Sidekiq's default
    # worker options. Otherwise, they will be based on the job class's options.
    #
    # Any options valid for a worker class's sidekiq_options are also available here.
    #
    # All options must be strings, not symbols.  NB: because we are serializing to JSON, all
    # symbols in 'args' will be converted to strings.  Note that +backtrace: true+ can take quite a bit of
    # space in Redis; a large volume of failing jobs can start Redis swapping if you aren't careful.
    #
    # Returns a unique Job ID.  If middleware stops the job, nil will be returned instead.
    #
    # Example:
    #   push('queue' => 'my_queue', 'class' => MyWorker, 'args' => ['foo', 1, :bat => 'bar'])
    #
    def push(item)
      normed = normalize_item(item)
      payload = process_single(item["class"], normed)

      if payload
        raw_push([payload])
        payload["jid"]
      end
    end

    ##
    # Push a large number of jobs to Redis. This method cuts out the redis
    # network round trip latency.  I wouldn't recommend pushing more than
    # 1000 per call but YMMV based on network quality, size of job args, etc.
    # A large number of jobs can cause a bit of Redis command processing latency.
    #
    # Takes the same arguments as #push except that args is expected to be
    # an Array of Arrays.  All other keys are duplicated for each job.  Each job
    # is run through the client middleware pipeline and each job gets its own Job ID
    # as normal.
    #
    # Returns an array of the of pushed jobs' jids.  The number of jobs pushed can be less
    # than the number given if the middleware stopped processing for one or more jobs.
    def push_bulk(items)
      args = items["args"]
      raise ArgumentError, "Bulk arguments must be an Array of Arrays: [[1], [2]]" unless args.is_a?(Array) && args.all?(Array)
      return [] if args.empty? # no jobs to push

      at = items.delete("at")
      raise ArgumentError, "Job 'at' must be a Numeric or an Array of Numeric timestamps" if at && (Array(at).empty? || !Array(at).all? { |entry| entry.is_a?(Numeric) })
      raise ArgumentError, "Job 'at' Array must have same size as 'args' Array" if at.is_a?(Array) && at.size != args.size

      normed = normalize_item(items)
      payloads = args.map.with_index { |job_args, index|
        copy = normed.merge("args" => job_args, "jid" => SecureRandom.hex(12), "enqueued_at" => Time.now.to_f)
        copy["at"] = (at.is_a?(Array) ? at[index] : at) if at

        result = process_single(items["class"], copy)
        result || nil
      }.compact

      raw_push(payloads) unless payloads.empty?
      payloads.collect { |payload| payload["jid"] }
    end

    # Allows sharding of jobs across any number of Redis instances.  All jobs
    # defined within the block will use the given Redis connection pool.
    #
    #   pool = ConnectionPool.new { Redis.new }
    #   Sidekiq::Client.via(pool) do
    #     SomeWorker.perform_async(1,2,3)
    #     SomeOtherWorker.perform_async(1,2,3)
    #   end
    #
    # Generally this is only needed for very large Sidekiq installs processing
    # thousands of jobs per second.  I do not recommend sharding unless
    # you cannot scale any other way (e.g. splitting your app into smaller apps).
    def self.via(pool)
      raise ArgumentError, "No pool given" if pool.nil?
      current_sidekiq_pool = Thread.current[:sidekiq_via_pool]
      Thread.current[:sidekiq_via_pool] = pool
      yield
    ensure
      Thread.current[:sidekiq_via_pool] = current_sidekiq_pool
    end

    class << self
      def push(item)
        new.push(item)
      end

      def push_bulk(items)
        new.push_bulk(items)
      end

      # Resque compatibility helpers.  Note all helpers
      # should go through Worker#client_push.
      #
      # Example usage:
      #   Sidekiq::Client.enqueue(MyWorker, 'foo', 1, :bat => 'bar')
      #
      # Messages are enqueued to the 'default' queue.
      #
      def enqueue(klass, *args)
        klass.client_push("class" => klass, "args" => args)
      end

      # Example usage:
      #   Sidekiq::Client.enqueue_to(:queue_name, MyWorker, 'foo', 1, :bat => 'bar')
      #
      def enqueue_to(queue, klass, *args)
        klass.client_push("queue" => queue, "class" => klass, "args" => args)
      end

      # Example usage:
      #   Sidekiq::Client.enqueue_to_in(:queue_name, 3.minutes, MyWorker, 'foo', 1, :bat => 'bar')
      #
      def enqueue_to_in(queue, interval, klass, *args)
        int = interval.to_f
        now = Time.now.to_f
        ts = (int < 1_000_000_000 ? now + int : int)

        item = {"class" => klass, "args" => args, "at" => ts, "queue" => queue}
        item.delete("at") if ts <= now

        klass.client_push(item)
      end

      # Example usage:
      #   Sidekiq::Client.enqueue_in(3.minutes, MyWorker, 'foo', 1, :bat => 'bar')
      #
      def enqueue_in(interval, klass, *args)
        klass.perform_in(interval, *args)
      end
    end

    private

    def raw_push(payloads)
      @redis_pool.with do |conn|
        conn.multi do
          atomic_push(conn, payloads)
        end
      end
      true
    end

    def atomic_push(conn, payloads)
      if payloads.first.key?("at")
        conn.zadd("schedule", payloads.map { |hash|
          at = hash.delete("at").to_s
          [at, Sidekiq.dump_json(hash)]
        })
      else
        queue = payloads.first["queue"]
        now = Time.now.to_f
        to_push = payloads.map { |entry|
          entry["enqueued_at"] = now
          Sidekiq.dump_json(entry)
        }
        conn.sadd("queues", queue)
        conn.lpush("queue:#{queue}", to_push)
      end
    end

    def process_single(worker_class, item)
      queue = item["queue"]

      middleware.invoke(worker_class, item, queue, @redis_pool) do
        item
      end
    end

    def validate(item)
      raise(ArgumentError, "Job must be a Hash with 'class' and 'args' keys: `#{item}`") unless item.is_a?(Hash) && item.key?("class") && item.key?("args")
      raise(ArgumentError, "Job args must be an Array: `#{item}`") unless item["args"].is_a?(Array)
      raise(ArgumentError, "Job class must be either a Class or String representation of the class name: `#{item}`") unless item["class"].is_a?(Class) || item["class"].is_a?(String)
      raise(ArgumentError, "Job 'at' must be a Numeric timestamp: `#{item}`") if item.key?("at") && !item["at"].is_a?(Numeric)
      raise(ArgumentError, "Job tags must be an Array: `#{item}`") if item["tags"] && !item["tags"].is_a?(Array)
    end

    def normalize_item(item)
      validate(item)
      # raise(ArgumentError, "Arguments must be native JSON types, see https://github.com/mperham/sidekiq/wiki/Best-Practices") unless JSON.load(JSON.dump(item['args'])) == item['args']

      # merge in the default sidekiq_options for the item's class and/or wrapped element
      # this allows ActiveJobs to control sidekiq_options too.
      defaults = normalized_hash(item["class"])
      defaults = defaults.merge(item["wrapped"].get_sidekiq_options) if item["wrapped"].respond_to?("get_sidekiq_options")
      item = defaults.merge(item)

      raise(ArgumentError, "Job must include a valid queue name") if item["queue"].nil? || item["queue"] == ""

      item["class"] = item["class"].to_s
      item["queue"] = item["queue"].to_s
      item["jid"] ||= SecureRandom.hex(12)
      item["created_at"] ||= Time.now.to_f

      item
    end

    def normalized_hash(item_class)
      if item_class.is_a?(Class)
        raise(ArgumentError, "Message must include a Sidekiq::Worker class, not class name: #{item_class.ancestors.inspect}") unless item_class.respond_to?("get_sidekiq_options")
        item_class.get_sidekiq_options
      else
        Sidekiq.default_worker_options
      end
    end
  end
end

# frozen_string_literal: true
require 'sidekiq'

module Sidekiq
  # PATCH: Centralize fetch strategy
  class Fetcher
    def self.strategy(strategy=nil)
      if ENV['SCHEDULE']
        ScheduleFetch
      else
        strategy || BasicFetch
      end
    end
  end

  class BasicFetch
    # We want the fetch operation to timeout every few seconds so the thread
    # can check if the process is shutting down.
    TIMEOUT = 2

    UnitOfWork = Struct.new(:queue, :job) do
      def acknowledge
        # nothing to do
      end

      def queue_name
        queue.sub(/.*queue:/, ''.freeze)
      end

      def requeue
        Sidekiq.redis do |conn|
          conn.rpush("queue:#{queue_name}", job)
        end
      end
    end

    def initialize(options)
      @strictly_ordered_queues = !!options[:strict]
      @queues = options[:queues].map { |q| "queue:#{q}" }
      if @strictly_ordered_queues
        @queues = @queues.uniq
        @queues << TIMEOUT
      end
    end

    def retrieve_work
      work = Sidekiq.redis { |conn| conn.brpop(*queues_cmd) }
      UnitOfWork.new(*work) if work
    end

    # Creating the Redis#brpop command takes into account any
    # configured queue weights. By default Redis#brpop returns
    # data from the first queue that has pending elements. We
    # recreate the queue command each time we invoke Redis#brpop
    # to honor weights and avoid queue starvation.
    def queues_cmd
      if @strictly_ordered_queues
        @queues
      else
        queues = @queues.shuffle.uniq
        queues << TIMEOUT
        queues
      end
    end


    # By leaving this as a class method, it can be pluggable and used by the Manager actor. Making it
    # an instance method will make it async to the Fetcher actor
    def self.bulk_requeue(inprogress, options)
      return if inprogress.empty?

      Sidekiq.logger.debug { "Re-queueing terminated jobs" }
      jobs_to_requeue = {}
      inprogress.each do |unit_of_work|
        jobs_to_requeue[unit_of_work.queue_name] ||= []
        jobs_to_requeue[unit_of_work.queue_name] << unit_of_work.job
      end

      Sidekiq.redis do |conn|
        conn.pipelined do
          jobs_to_requeue.each do |queue, jobs|
            conn.rpush("queue:#{queue}", jobs)
          end
        end
      end
      Sidekiq.logger.info("Pushed #{inprogress.size} jobs back to Redis")
    rescue => ex
      Sidekiq.logger.warn("Failed to requeue #{inprogress.size} jobs: #{ex.message}")
    end

  end

  # PATCH: Scheduled fetcher strategy
  class ScheduleFetch
    ZPOP = <<-LUA
      local val = redis.call('zrangebyscore', KEYS[1], '-inf', KEYS[2], 'LIMIT', 0, 1)
      if val then redis.call('zrem', KEYS[1], val[1]) end
      return val[1]
    LUA

    def initialize(options)
      @queues = %w(schedule)
    end

    def retrieve_work
      work = Sidekiq.redis { |conn|
        sorted_set = @queues.sample
        namespace = conn.namespace
        now = Time.now.to_f.to_s

        message = conn.eval(ZPOP, ["#{namespace}:#{sorted_set}", now], {})
        if message
          msg = Sidekiq.load_json(message)

          # Keep message in schedule
          if sorted_set == 'schedule'
            conn.zadd('schedule', (Time.new + msg['expiration']).to_f.to_s, message)
          end

          ["queue:#{msg['queue']}", message]
        end
      }
      UnitOfWork.new(*work) if work
    end

    def self.bulk_requeue(inprogress)
      Sidekiq.logger.debug { "Re-queueing terminated jobs" }
      jobs_to_requeue = {}
      inprogress.each do |unit_of_work|
        jobs_to_requeue[unit_of_work.queue_name] ||= []
        jobs_to_requeue[unit_of_work.queue_name] << unit_of_work.message
      end

      Sidekiq.redis do |conn|
        jobs_to_requeue.each do |queue, jobs|
          conn.rpush("queue:#{queue}", jobs)
        end
      end
      Sidekiq.logger.info("Pushed #{inprogress.size} messages back to Redis")
    rescue => ex
      Sidekiq.logger.warn("Failed to requeue #{inprogress.size} jobs: #{ex.message}")
    end

    UnitOfWork = Struct.new(:queue, :message) do
      def acknowledge
        # nothing to do
      end

      def queue_name
        queue.gsub(/.*queue:/, '')
      end

      def requeue
        Sidekiq.redis do |conn|
          conn.rpush("queue:#{queue_name}", message)
        end
      end
    end
  end
end

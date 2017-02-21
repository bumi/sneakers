require 'sneakers/queue'
require 'sneakers/support/utils'
require 'timeout'

module Sneakers
  module Worker
    attr_reader :queue, :id, :opts

    # For now, a worker is hardly dependant on these concerns
    # (because it uses methods from them directly.)
    include Concerns::Logging
    include Concerns::Metrics
    include Sneakers::ErrorReporter

    def initialize(queue = nil, pool = nil, opts = {})
      opts = opts.merge(self.class.queue_opts || {})
      queue_name = self.class.queue_name
      opts = Sneakers::CONFIG.merge(opts)

      @should_ack =  opts[:ack]
      @timeout_after = opts[:timeout_job_after]
      @pool = pool || Thread.pool(opts[:threads]) # XXX config threads
      @call_with_params = respond_to?(:work_with_params)

      @queue = queue || Sneakers::Queue.new(
        queue_name,
        opts
      )

      @opts = opts
      @id = Utils.make_worker_id(queue_name)
    end

    def ack!; :ack end
    def reject!; :reject; end
    def requeue!; :requeue; end

    def publish(msg, opts)
      to_queue = opts.delete(:to_queue)
      opts[:routing_key] ||= to_queue
      return unless opts[:routing_key]
      @queue.exchange.publish(msg, opts)
    end

    def do_work(delivery_info, metadata, msg, handler)
      worker_trace "Working off: #{msg.inspect}"

      @pool.process do
        res = nil
        error = nil

        begin
          metrics.increment("work.#{self.class.name}.started")
          Timeout.timeout(@timeout_after, WorkerTimeout) do
            metrics.timing("work.#{self.class.name}.time") do
              if @call_with_params
                res = work_with_params(msg, delivery_info, metadata)
              else
                res = work(msg)
              end
            end
          end
        rescue WorkerTimeout => ex
          res = :timeout
          worker_error(ex, log_msg: log_msg(msg), class: self.class.name,
                       message: msg, delivery_info: delivery_info, metadata: metadata)
        rescue => ex
          res = :error
          error = ex
          worker_error(ex, log_msg: log_msg(msg), class: self.class.name,
                       message: msg, delivery_info: delivery_info, metadata: metadata)
        end

        if @should_ack

          if res == :ack
            # note to future-self. never acknowledge multiple (multiple=true) messages under threads.
            handler.acknowledge(delivery_info, metadata, msg)
          elsif res == :timeout
            handler.timeout(delivery_info, metadata, msg)
          elsif res == :error
            handler.error(delivery_info, metadata, msg, error)
          elsif res == :reject
            handler.reject(delivery_info, metadata, msg)
          elsif res == :requeue
            handler.reject(delivery_info, metadata, msg, true)
          else
            handler.noop(delivery_info, metadata, msg)
          end
          metrics.increment("work.#{self.class.name}.handled.#{res || 'noop'}")
        end

        metrics.increment("work.#{self.class.name}.ended")
      end #process
    end

    def stop
      worker_trace "Stopping worker: shutting down thread pool."
      @pool.shutdown
      worker_trace "Stopping worker: unsubscribing."
      @queue.unsubscribe
      worker_trace "Stopping worker: I'm gone."
    end

    def run
      worker_trace "New worker: subscribing."
      @queue.subscribe(self)
      worker_trace "New worker: I'm alive."
    end

    # Construct a log message with some standard prefix for this worker
    def log_msg(msg)
      "[#{@id}][#{Thread.current}][#{@queue.name}][#{@queue.opts}] #{msg}"
    end

    def worker_trace(msg)
      logger.debug(log_msg(msg))
    end

    Classes = []

    def self.included(base)
      base.extend ClassMethods
      Classes << base if base.is_a? Class
    end

    module ClassMethods
      attr_reader :queue_opts
      attr_reader :queue_name

      def from_queue(q, opts={})
        @queue_name = q.to_s
        @queue_opts = opts
      end

      def enqueue(msg, opts={})
        opts[:routing_key] ||= @queue_opts[:routing_key]
        opts[:to_queue] ||= @queue_name

        publisher.publish(msg, opts)
      end

      private

      def publisher
        @publisher ||= Sneakers::Publisher.new(queue_opts)
      end
    end
  end
end


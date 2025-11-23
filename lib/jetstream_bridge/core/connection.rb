# frozen_string_literal: true

require 'nats/io/client'
require 'singleton'
require 'oj'
require_relative 'duration'
require_relative 'logging'
require_relative 'config'
require_relative '../topology/topology'

module JetstreamBridge
  # Singleton connection to NATS with thread-safe initialization.
  #
  # This class manages a single NATS connection for the entire application,
  # ensuring thread-safe access in multi-threaded environments like Rails
  # with Puma or Sidekiq.
  #
  # Thread Safety:
  # - Connection initialization is synchronized with a mutex
  # - The singleton pattern ensures only one connection instance exists
  # - Safe to call from multiple threads/workers simultaneously
  #
  # Example:
  #   # Safe from any thread
  #   jts = JetstreamBridge::Connection.connect!
  #   jts.publish(...)
  class Connection
    include Singleton

    DEFAULT_CONN_OPTS = {
      reconnect: true,
      reconnect_time_wait: 2,
      max_reconnect_attempts: 10,
      connect_timeout: 5
    }.freeze

    class << self
      # Thread-safe delegator to the singleton instance.
      # Returns a live JetStream context.
      #
      # Safe to call from multiple threads - uses mutex for synchronization.
      #
      # @return [NATS::JetStream::JS] JetStream context
      def connect!
        @__mutex ||= Mutex.new
        @__mutex.synchronize { instance.connect! }
      end

      # Optional accessors if callers need raw handles
      def nc
        instance.__send__(:nc)
      end

      def jetstream
        instance.__send__(:jetstream)
      end
    end

    # Idempotent: returns an existing, healthy JetStream context or establishes one.
    def connect!
      return @jts if connected?

      servers = nats_servers
      raise 'No NATS URLs configured' if servers.empty?

      establish_connection(servers)

      Logging.info(
        "Connected to NATS (#{servers.size} server#{'s' unless servers.size == 1}): " \
        "#{sanitize_urls(servers).join(', ')}",
        tag: 'JetstreamBridge::Connection'
      )

      # Ensure topology (streams, subjects, overlap guard, etc.)
      Topology.ensure!(@jts)

      @connected_at = Time.now.utc
      @jts
    end

    # Public API for checking connection status
    # @return [Boolean] true if NATS client is connected and JetStream is healthy
    def connected?
      return false unless @nc&.connected?
      return false unless @jts

      jetstream_healthy?
    end

    # Public API for getting connection timestamp
    # @return [Time, nil] timestamp when connection was established
    attr_reader :connected_at

    private

    def jetstream_healthy?
      # Verify JetStream responds to simple API call
      @jts.account_info
      true
    rescue StandardError => e
      Logging.warn(
        "JetStream health check failed: #{e.class} #{e.message}",
        tag: 'JetstreamBridge::Connection'
      )
      false
    end

    def nats_servers
      JetstreamBridge.config.nats_urls
                     .to_s
                     .split(',')
                     .map(&:strip)
                     .reject(&:empty?)
    end

    def establish_connection(servers)
      @nc = NATS::IO::Client.new

      # Setup reconnect handler to refresh JetStream context
      @nc.on_reconnect do
        Logging.info(
          'NATS reconnected, refreshing JetStream context',
          tag: 'JetstreamBridge::Connection'
        )
        refresh_jetstream_context
      end

      @nc.on_disconnect do |reason|
        Logging.warn(
          "NATS disconnected: #{reason}",
          tag: 'JetstreamBridge::Connection'
        )
      end

      @nc.on_error do |err|
        Logging.error(
          "NATS error: #{err}",
          tag: 'JetstreamBridge::Connection'
        )
      end

      @nc.connect({ servers: servers }.merge(DEFAULT_CONN_OPTS))

      # Create JetStream context
      @jts = @nc.jetstream

      # Ensure JetStream responds to #nc
      return if @jts.respond_to?(:nc)

      nc_ref = @nc
      @jts.define_singleton_method(:nc) { nc_ref }
    end

    def refresh_jetstream_context
      @jts = @nc.jetstream
      nc_ref = @nc
      @jts.define_singleton_method(:nc) { nc_ref } unless @jts.respond_to?(:nc)

      # Re-ensure topology after reconnect
      Topology.ensure!(@jts)
    rescue StandardError => e
      Logging.error(
        "Failed to refresh JetStream context: #{e.class} #{e.message}",
        tag: 'JetstreamBridge::Connection'
      )
    end

    # Expose for class-level helpers (not part of public API)
    attr_reader :nc

    def jetstream
      @jts
    end

    # Mask credentials in NATS URLs:
    # - "nats://user:pass@host:4222" -> "nats://user:***@host:4222"
    # - "nats://token@host:4222"     -> "nats://***@host:4222"
    def sanitize_urls(urls)
      urls.map { |u| Logging.sanitize_url(u) }
    end
  end
end

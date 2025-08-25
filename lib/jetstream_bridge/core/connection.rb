# frozen_string_literal: true

require 'nats/io/client'
require 'singleton'
require 'oj'
require_relative 'duration'
require_relative 'logging'
require_relative 'config'
require_relative '../topology/topology'

module JetstreamBridge
  # Singleton connection to NATS.
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

      @jts
    end

    private

    def connected?
      @nc&.connected?
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
      @nc.connect({ servers: servers }.merge(DEFAULT_CONN_OPTS))

      # Create JetStream context
      @jts = @nc.jetstream

      # --- Compatibility shim: ensure JetStream responds to #nc for older/newer clients ---
      return if @jts.respond_to?(:nc)

      nc_ref = @nc
      @jts.define_singleton_method(:nc) { nc_ref }
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

# frozen_string_literal: true

require 'nats/io/client'
require 'singleton'
require 'json'
require_relative 'duration'
require_relative 'logging'

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

    # --- class-level entrypoint expected by Publisher ---
    class << self
      # Thread-safe delegator to the singleton instance
      def connect!
        @__mutex ||= Mutex.new
        @__mutex.synchronize { instance.connect! }
      end
    end

    # Idempotent: returns an existing, healthy JetStream context or establishes one.
    def connect!
      return @jts if connected?

      servers = nats_servers
      raise 'No NATS URLs configured' if servers.empty?

      establish_connection(servers)
      Logging.info("Connected to NATS: #{servers.join(',')}", tag: 'JetstreamBridge::Connection')

      Topology.ensure!(@jts)
      @jts
    end

    private

    # Prefer checking the underlying NATS client for connection health.
    # Not all JetStream context objects expose `connected?`.
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
      @jts = @nc.jetstream
    end
  end
end

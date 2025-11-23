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

    VALID_NATS_SCHEMES = %w[nats nats+tls].freeze

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
      servers = JetstreamBridge.config.nats_urls
                               .to_s
                               .split(',')
                               .map(&:strip)
                               .reject(&:empty?)

      validate_nats_urls!(servers)
      servers
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

      # Verify connection is established
      verify_connection!

      # Create JetStream context
      @jts = @nc.jetstream

      # Verify JetStream is available
      verify_jetstream!

      # Ensure JetStream responds to #nc
      return if @jts.respond_to?(:nc)

      nc_ref = @nc
      @jts.define_singleton_method(:nc) { nc_ref }
    end

    def validate_nats_urls!(servers)
      Logging.debug(
        "Validating #{servers.size} NATS URL(s): #{sanitize_urls(servers).join(', ')}",
        tag: 'JetstreamBridge::Connection'
      )

      servers.each do |url|
        # Check for basic URL format (scheme://host)
        unless url.include?('://')
          Logging.error(
            "Invalid URL format (missing scheme): #{url}",
            tag: 'JetstreamBridge::Connection'
          )
          raise ConnectionError, "Invalid NATS URL format: #{url}. Expected format: nats://host:port"
        end

        uri = URI.parse(url)

        # Validate scheme
        scheme = uri.scheme&.downcase
        unless VALID_NATS_SCHEMES.include?(scheme)
          Logging.error(
            "Invalid URL scheme '#{uri.scheme}': #{Logging.sanitize_url(url)}",
            tag: 'JetstreamBridge::Connection'
          )
          raise ConnectionError, "Invalid NATS URL scheme '#{uri.scheme}' in: #{url}. Expected 'nats' or 'nats+tls'"
        end

        # Validate host is present
        if uri.host.nil? || uri.host.empty?
          Logging.error(
            "Missing host in URL: #{Logging.sanitize_url(url)}",
            tag: 'JetstreamBridge::Connection'
          )
          raise ConnectionError, "Invalid NATS URL - missing host: #{url}"
        end

        # Validate port if present
        if uri.port && (uri.port < 1 || uri.port > 65_535)
          Logging.error(
            "Invalid port #{uri.port} in URL: #{Logging.sanitize_url(url)}",
            tag: 'JetstreamBridge::Connection'
          )
          raise ConnectionError, "Invalid NATS URL - port must be 1-65535: #{url}"
        end

        Logging.debug(
          "URL validated: #{Logging.sanitize_url(url)}",
          tag: 'JetstreamBridge::Connection'
        )
      rescue URI::InvalidURIError => e
        Logging.error(
          "Malformed URL: #{url} (#{e.message})",
          tag: 'JetstreamBridge::Connection'
        )
        raise ConnectionError, "Invalid NATS URL format: #{url} (#{e.message})"
      end

      Logging.info(
        'All NATS URLs validated successfully',
        tag: 'JetstreamBridge::Connection'
      )
    end

    def verify_connection!
      Logging.debug(
        'Verifying NATS connection...',
        tag: 'JetstreamBridge::Connection'
      )

      unless @nc.connected?
        Logging.error(
          'NATS connection verification failed - client not connected',
          tag: 'JetstreamBridge::Connection'
        )
        raise ConnectionError, 'Failed to establish connection to NATS server(s)'
      end

      Logging.info(
        'NATS connection verified successfully',
        tag: 'JetstreamBridge::Connection'
      )
    end

    def verify_jetstream!
      Logging.debug(
        'Verifying JetStream availability...',
        tag: 'JetstreamBridge::Connection'
      )

      # Verify JetStream is enabled by checking account info
      account_info = @jts.account_info

      Logging.info(
        "JetStream verified - Streams: #{account_info.streams}, " \
        "Consumers: #{account_info.consumers}, " \
        "Memory: #{format_bytes(account_info.memory)}, " \
        "Storage: #{format_bytes(account_info.storage)}",
        tag: 'JetstreamBridge::Connection'
      )
    rescue NATS::IO::NoRespondersError
      Logging.error(
        'JetStream not available - no responders (JetStream not enabled)',
        tag: 'JetstreamBridge::Connection'
      )
      raise ConnectionError, 'JetStream not enabled on NATS server. Please enable JetStream with -js flag'
    rescue StandardError => e
      Logging.error(
        "JetStream verification failed: #{e.class} - #{e.message}",
        tag: 'JetstreamBridge::Connection'
      )
      raise ConnectionError, "JetStream verification failed: #{e.message}"
    end

    def format_bytes(bytes)
      return 'N/A' if bytes.nil? || bytes.zero?

      units = %w[B KB MB GB TB]
      exp = (Math.log(bytes) / Math.log(1024)).to_i
      exp = [exp, units.length - 1].min
      "#{(bytes / (1024.0**exp)).round(2)} #{units[exp]}"
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

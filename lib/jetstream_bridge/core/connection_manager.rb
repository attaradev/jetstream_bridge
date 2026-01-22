# frozen_string_literal: true

require 'nats/io/client'
require 'uri'
require_relative 'logging'
require_relative 'config'
require_relative '../topology/topology'

module JetstreamBridge
  # Manages NATS connection lifecycle
  #
  # Responsible for:
  # - Establishing and closing connections
  # - Validating connection URLs
  # - Health checking
  # - Reconnection handling
  # - JetStream context management
  #
  # NOT a singleton - instances are created and injected
  class ConnectionManager
    # Connection states for observability
    module State
      DISCONNECTED = :disconnected
      CONNECTING = :connecting
      CONNECTED = :connected
      RECONNECTING = :reconnecting
      FAILED = :failed
    end

    # Valid NATS URL schemes
    VALID_NATS_SCHEMES = %w[nats nats+tls].freeze

    DEFAULT_CONN_OPTS = {
      reconnect: true,
      reconnect_time_wait: 2,
      max_reconnect_attempts: 10,
      connect_timeout: 5
    }.freeze

    # Health check cache TTL in seconds
    HEALTH_CHECK_CACHE_TTL = 30

    attr_reader :config, :connected_at, :last_reconnect_error, :last_reconnect_error_at, :state

    # @param config [Config] Configuration instance
    def initialize(config)
      @config = config
      @mutex = Mutex.new
      @state = State::DISCONNECTED
      @nc = nil
      @jts = nil
      @connected_at = nil
      @cached_health_status = nil
      @last_health_check = nil
      @reconnecting = false
    end

    # Establish connection to NATS and ensure topology
    #
    # Idempotent - safe to call multiple times
    #
    # @return [NATS::JetStream::JS] JetStream context
    # @raise [ConnectionError] If connection fails
    def connect!
      @mutex.synchronize do
        return @jts if connected_without_lock?

        servers = validate_and_parse_servers!(@config.nats_urls)
        @state = State::CONNECTING

        establish_connection_with_retry(servers)

        Logging.info(
          "Connected to NATS (#{servers.size} server#{'s' unless servers.size == 1}): " \
          "#{sanitize_urls(servers).join(', ')}",
          tag: 'JetstreamBridge::ConnectionManager'
        )

        ensure_topology_if_enabled

        @connected_at = Time.now.utc
        @state = State::CONNECTED
        @jts
      end
    rescue StandardError
      @state = State::FAILED
      cleanup_connection!
      raise
    end

    # Close the NATS connection
    #
    # @return [void]
    def disconnect!
      @mutex.synchronize do
        cleanup_connection!(close_nc: true)
        @state = State::DISCONNECTED
        Logging.info('Disconnected from NATS', tag: 'JetstreamBridge::ConnectionManager')
      end
    end

    # Reconnect to NATS (disconnect + connect)
    #
    # @return [void]
    def reconnect!
      Logging.info('Reconnecting to NATS...', tag: 'JetstreamBridge::ConnectionManager')
      disconnect!
      connect!
    end

    # Get JetStream context
    #
    # @return [NATS::JetStream::JS, nil] JetStream context if connected
    def jetstream
      @jts
    end

    # Get raw NATS client
    #
    # @return [NATS::IO::Client, nil] NATS client if connected
    def nats_client
      @nc
    end

    # Check if connected and healthy
    #
    # @param skip_cache [Boolean] Force fresh health check
    # @return [Boolean] true if connected and healthy
    def connected?(skip_cache: false)
      return false unless @nc&.connected?
      return false unless @jts

      # Use cached result if available and fresh
      now = Time.now.to_i
      if !skip_cache && @last_health_check && (now - @last_health_check) < HEALTH_CHECK_CACHE_TTL
        return @cached_health_status
      end

      # Thread-safe cache update
      @mutex.synchronize do
        # Double-check after acquiring lock
        now = Time.now.to_i
        if !skip_cache && @last_health_check && (now - @last_health_check) < HEALTH_CHECK_CACHE_TTL
          return @cached_health_status
        end

        # Perform actual health check
        @cached_health_status = jetstream_healthy?
        @last_health_check = now
        @cached_health_status
      end
    end

    # Get detailed health status
    #
    # @param skip_cache [Boolean] Force fresh check
    # @return [Hash] Health status details
    def health_check(skip_cache: false)
      {
        connected: connected?(skip_cache: skip_cache),
        state: @state,
        connected_at: @connected_at&.iso8601,
        last_error: @last_reconnect_error&.message,
        last_error_at: @last_reconnect_error_at&.iso8601
      }
    end

    private

    def connected_without_lock?
      @jts && @nc&.connected?
    end

    def jetstream_healthy?
      return true if @config.disable_js_api

      # Verify JetStream responds to simple API call
      @jts.account_info
      true
    rescue StandardError => e
      Logging.warn(
        "JetStream health check failed: #{e.class} #{e.message}",
        tag: 'JetstreamBridge::ConnectionManager'
      )
      false
    end

    def establish_connection_with_retry(servers)
      attempts = 0
      max_attempts = @config.connect_retry_attempts
      retry_delay = @config.connect_retry_delay

      begin
        attempts += 1
        establish_connection(servers)
      rescue ConnectionError => e
        if attempts < max_attempts
          delay = retry_delay * attempts
          Logging.warn(
            "Connection attempt #{attempts}/#{max_attempts} failed: #{e.message}. " \
            "Retrying in #{delay}s...",
            tag: 'JetstreamBridge::ConnectionManager'
          )
          sleep(delay)
          retry
        else
          Logging.error(
            "Failed to establish connection after #{attempts} attempts",
            tag: 'JetstreamBridge::ConnectionManager'
          )
          raise
        end
      end
    end

    def establish_connection(servers)
      @nc = create_nats_client

      setup_callbacks

      connect_opts = { servers: servers }.merge(DEFAULT_CONN_OPTS)
      inbox_prefix = @config.inbox_prefix.to_s.strip
      connect_opts[:inbox_prefix] = inbox_prefix unless inbox_prefix.empty?

      @nc.connect(connect_opts) unless skip_connect?

      verify_connection!

      # Create JetStream context
      @jts = @nc.jetstream

      verify_jetstream!

      # Ensure JetStream responds to #nc
      add_nc_accessor unless @jts.respond_to?(:nc)
    end

    def create_nats_client
      # Use mock NATS client if explicitly enabled for testing
      if test_mode?
        JetstreamBridge.instance_variable_get(:@mock_nats_client)
      else
        NATS::IO::Client.new
      end
    end

    def test_mode?
      defined?(JetstreamBridge::TestHelpers) &&
        JetstreamBridge::TestHelpers.respond_to?(:test_mode?) &&
        JetstreamBridge::TestHelpers.test_mode? &&
        JetstreamBridge.instance_variable_defined?(:@mock_nats_client)
    end

    def skip_connect?
      @nc.connected? && test_mode?
    end

    def setup_callbacks
      @nc.on_reconnect do
        @reconnecting = true
        Logging.info(
          'NATS reconnected, refreshing JetStream context',
          tag: 'JetstreamBridge::ConnectionManager'
        )
        refresh_jetstream_context
        @reconnecting = false
      end

      @nc.on_disconnect do |reason|
        @state = State::DISCONNECTED
        Logging.warn(
          "NATS disconnected: #{reason}",
          tag: 'JetstreamBridge::ConnectionManager'
        )
      end

      @nc.on_error do |err|
        Logging.error(
          "NATS error: #{err}",
          tag: 'JetstreamBridge::ConnectionManager'
        )
      end
    end

    def add_nc_accessor
      nc_ref = @nc
      @jts.define_singleton_method(:nc) { nc_ref }
    end

    def verify_connection!
      Logging.debug(
        'Verifying NATS connection...',
        tag: 'JetstreamBridge::ConnectionManager'
      )

      unless @nc.connected?
        Logging.error(
          'NATS connection verification failed - client not connected',
          tag: 'JetstreamBridge::ConnectionManager'
        )
        raise ConnectionError, 'Failed to establish connection to NATS server(s)'
      end

      Logging.info(
        'NATS connection verified successfully',
        tag: 'JetstreamBridge::ConnectionManager'
      )
    end

    def verify_jetstream!
      return true if @config.disable_js_api

      Logging.debug(
        'Verifying JetStream availability...',
        tag: 'JetstreamBridge::ConnectionManager'
      )

      account_info = @jts.account_info

      # Handle both object-style and hash-style access for compatibility
      streams = account_info.respond_to?(:streams) ? account_info.streams : account_info[:streams]
      consumers = account_info.respond_to?(:consumers) ? account_info.consumers : account_info[:consumers]
      memory = account_info.respond_to?(:memory) ? account_info.memory : account_info[:memory]
      storage = account_info.respond_to?(:storage) ? account_info.storage : account_info[:storage]

      Logging.info(
        "JetStream verified - Streams: #{streams}, " \
        "Consumers: #{consumers}, " \
        "Memory: #{format_bytes(memory)}, " \
        "Storage: #{format_bytes(storage)}",
        tag: 'JetstreamBridge::ConnectionManager'
      )
    rescue NATS::IO::NoRespondersError
      Logging.error(
        'JetStream not available - no responders (JetStream not enabled)',
        tag: 'JetstreamBridge::ConnectionManager'
      )
      raise ConnectionError, 'JetStream not enabled on NATS server. Please enable JetStream with -js flag'
    rescue StandardError => e
      Logging.error(
        "JetStream verification failed: #{e.class} - #{e.message}",
        tag: 'JetstreamBridge::ConnectionManager'
      )
      raise ConnectionError, "JetStream verification failed: #{e.message}"
    end

    def ensure_topology_if_enabled
      return if @config.disable_js_api

      Topology.ensure!(@jts, force: true)
    rescue StandardError => e
      Logging.warn(
        "Topology ensure skipped: #{e.class} #{e.message}",
        tag: 'JetstreamBridge::ConnectionManager'
      )
    end

    def refresh_jetstream_context
      @jts = @nc.jetstream
      add_nc_accessor unless @jts.respond_to?(:nc)
      ensure_topology_if_enabled

      # Invalidate health check cache on successful reconnect
      @cached_health_status = nil
      @last_health_check = nil

      # Clear error state on successful reconnect
      @last_reconnect_error = nil
      @last_reconnect_error_at = nil
      @state = State::CONNECTED

      Logging.info(
        'JetStream context refreshed successfully after reconnect',
        tag: 'JetstreamBridge::ConnectionManager'
      )
    rescue StandardError => e
      # Store error state for diagnostics
      @last_reconnect_error = e
      @last_reconnect_error_at = Time.now
      @state = State::FAILED
      cleanup_connection!(close_nc: false)
      Logging.error(
        "Failed to refresh JetStream context: #{e.class} #{e.message}",
        tag: 'JetstreamBridge::ConnectionManager'
      )

      # Invalidate health check cache to force re-check
      @cached_health_status = false
      @last_health_check = Time.now.to_i
    end

    def cleanup_connection!(close_nc: true)
      begin
        # Avoid touching RSpec doubles used in unit tests
        is_rspec_double = defined?(RSpec::Mocks::Double) && @nc.is_a?(RSpec::Mocks::Double)
        @nc.close if !is_rspec_double && close_nc && @nc.respond_to?(:close) && @nc.connected?
      rescue StandardError
        # ignore cleanup errors
      end
      @nc = nil
      @jts = nil
      @cached_health_status = nil
      @last_health_check = nil
      @connected_at = nil
    end

    def format_bytes(bytes)
      return 'N/A' if bytes.nil? || bytes.zero?

      units = %w[B KB MB GB TB]
      exp = (Math.log(bytes) / Math.log(1024)).to_i
      exp = [exp, units.length - 1].min
      "#{(bytes / (1024.0**exp)).round(2)} #{units[exp]}"
    end

    def sanitize_urls(urls)
      urls.map { |u| Logging.sanitize_url(u) }
    end

    # Validate and parse NATS server URLs
    #
    # @param urls [String] Comma-separated NATS URLs
    # @return [Array<String>] Validated server URLs
    # @raise [ConnectionError] If validation fails
    def validate_and_parse_servers!(urls)
      servers = parse_urls(urls)
      validate_not_empty!(servers)

      servers.each { |url| validate_url!(url) }

      Logging.info(
        'All NATS URLs validated successfully',
        tag: 'JetstreamBridge::ConnectionManager'
      )

      servers
    end

    def parse_urls(urls)
      urls.to_s
          .split(',')
          .map(&:strip)
          .reject(&:empty?)
    end

    def validate_not_empty!(servers)
      return unless servers.empty?

      raise ConnectionError, 'No NATS URLs configured'
    end

    def validate_url!(url)
      validate_url_format!(url)

      uri = URI.parse(url)
      validate_url_scheme!(uri, url)
      validate_url_host!(uri, url)
      validate_url_port!(uri, url)

      Logging.debug(
        "URL validated: #{Logging.sanitize_url(url)}",
        tag: 'JetstreamBridge::ConnectionManager'
      )
    rescue URI::InvalidURIError => e
      Logging.error(
        "Malformed URL: #{url} (#{e.message})",
        tag: 'JetstreamBridge::ConnectionManager'
      )
      raise ConnectionError, "Invalid NATS URL format: #{url} (#{e.message})"
    end

    def validate_url_format!(url)
      return if url.include?('://')

      Logging.error(
        "Invalid URL format (missing scheme): #{url}",
        tag: 'JetstreamBridge::ConnectionManager'
      )
      raise ConnectionError, "Invalid NATS URL format: #{url}. Expected format: nats://host:port"
    end

    def validate_url_scheme!(uri, url)
      scheme = uri.scheme&.downcase
      return if VALID_NATS_SCHEMES.include?(scheme)

      Logging.error(
        "Invalid URL scheme '#{uri.scheme}': #{Logging.sanitize_url(url)}",
        tag: 'JetstreamBridge::ConnectionManager'
      )
      raise ConnectionError, "Invalid NATS URL scheme '#{uri.scheme}' in: #{url}. Expected 'nats' or 'nats+tls'"
    end

    def validate_url_host!(uri, url)
      return unless uri.host.nil? || uri.host.empty?

      Logging.error(
        "Missing host in URL: #{Logging.sanitize_url(url)}",
        tag: 'JetstreamBridge::ConnectionManager'
      )
      raise ConnectionError, "Invalid NATS URL - missing host: #{url}"
    end

    def validate_url_port!(uri, url)
      return unless uri.port && (uri.port < 1 || uri.port > 65_535)

      Logging.error(
        "Invalid port #{uri.port} in URL: #{Logging.sanitize_url(url)}",
        tag: 'JetstreamBridge::ConnectionManager'
      )
      raise ConnectionError, "Invalid NATS URL - port must be 1-65535: #{url}"
    end
  end
end

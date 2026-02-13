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

    # Connection states for observability
    module State
      DISCONNECTED = :disconnected
      CONNECTING = :connecting
      CONNECTED = :connected
      RECONNECTING = :reconnecting
      FAILED = :failed
    end

    DEFAULT_CONN_OPTS = {
      reconnect: true,
      reconnect_time_wait: 2,
      max_reconnect_attempts: 10,
      connect_timeout: 5
    }.freeze

    VALID_NATS_SCHEMES = %w[nats nats+tls].freeze
    REFRESH_RETRY_BASE_DELAY = 0.01
    REFRESH_RETRY_MAX_DELAY = 30.0
    REFRESH_RETRY_MAX_ATTEMPTS = 30

    # Class-level mutex for thread-safe connection initialization
    # Using class variable to avoid race condition in mutex creation
    # rubocop:disable Style/ClassVars
    @@connection_lock = Mutex.new
    # rubocop:enable Style/ClassVars

    class << self
      # Thread-safe delegator to the singleton instance.
      # Returns a live JetStream context.
      #
      # Safe to call from multiple threads - uses class-level mutex for synchronization.
      #
      # @return [NATS::JetStream] JetStream context
      def connect!(verify_js: nil)
        @@connection_lock.synchronize { instance.connect!(verify_js: verify_js) }
      end

      # Returns the raw NATS client from the singleton instance.
      #
      # @return [NATS::IO::Client, nil] The underlying NATS connection
      def nc
        instance.__send__(:nc)
      end

      # Returns the JetStream context from the singleton instance.
      #
      # @return [NATS::JetStream, nil] JetStream context
      # @raise [ConnectionNotEstablishedError] If JetStream context is unavailable
      def jetstream
        instance.__send__(:jetstream)
      end
    end

    # Idempotent: returns an existing, healthy JetStream context or establishes one.
    #
    # @param verify_js [Boolean, nil] Whether to verify JetStream availability via account_info.
    #   Defaults to the value of {Config#auto_provision}.
    # @return [NATS::JetStream] JetStream context
    # @raise [ConnectionError] If unable to connect to NATS or JetStream
    def connect!(verify_js: nil)
      verify_js = config_auto_provision if verify_js.nil?
      # Check if already connected without acquiring mutex (for performance)
      return @jts if @jts && @nc&.connected?

      servers = nats_servers
      raise 'No NATS URLs configured' if servers.empty?

      @state = State::CONNECTING
      establish_connection_with_retry(servers, verify_js: verify_js)

      Logging.info(
        "Connected to NATS (#{servers.size} server#{'s' unless servers.size == 1}): " \
        "#{sanitize_urls(servers).join(', ')}",
        tag: 'JetstreamBridge::Connection'
      )

      @connected_at = Time.now.utc
      @state = State::CONNECTED
      @jts
    rescue StandardError
      @state = State::FAILED
      cleanup_connection!
      raise
    end

    # Public API for checking connection status
    #
    # Uses cached health check result to avoid excessive network calls.
    # Cache expires after 30 seconds.
    #
    # Thread-safe: Cache updates are synchronized to prevent race conditions.
    #
    # @param skip_cache [Boolean] Force fresh health check, bypass cache
    # @return [Boolean] true if NATS client is connected and JetStream is healthy
    def connected?(skip_cache: false)
      return false unless @nc&.connected?
      return false unless @jts

      # Use cached result if available and fresh
      now = Time.now.to_i
      return @cached_health_status if !skip_cache && @last_health_check && (now - @last_health_check) < 30

      # Thread-safe cache update to prevent race conditions
      @@connection_lock.synchronize do
        # Double-check after acquiring lock (another thread may have updated)
        now = Time.now.to_i
        return @cached_health_status if !skip_cache && @last_health_check && (now - @last_health_check) < 30

        # Perform actual health check (management APIs optional)
        @cached_health_status = jetstream_healthy?(verify_js: config_auto_provision)
        @last_health_check = now
        @cached_health_status
      end
    end

    # Public API for getting connection timestamp
    # @return [Time, nil] timestamp when connection was established
    attr_reader :connected_at

    # Last reconnection error metadata (exposed for health checks/diagnostics)
    attr_reader :last_reconnect_error, :last_reconnect_error_at

    # Get current connection state
    #
    # @return [Symbol] Current connection state (see State module)
    def state
      return State::DISCONNECTED unless @nc
      return State::FAILED if @last_reconnect_error && !@nc.connected?
      return State::RECONNECTING if @reconnecting

      @nc.connected? ? (@state || State::CONNECTED) : State::DISCONNECTED
    end

    private

    def jetstream_healthy?(verify_js:)
      # Lightweight health when management APIs are disabled
      return ping_only_health unless verify_js

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

    def ping_only_health
      return false unless @nc&.connected?

      # Flush acts as a ping/pong round-trip without hitting JetStream management subjects
      @nc.flush(0.5)
      true
    rescue StandardError => e
      Logging.warn(
        "NATS connectivity check failed: #{e.class} #{e.message}",
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

    def establish_connection_with_retry(servers, verify_js:)
      attempts = 0
      max_attempts = JetstreamBridge.config.connect_retry_attempts
      retry_delay = JetstreamBridge.config.connect_retry_delay

      begin
        attempts += 1
        establish_connection(servers, verify_js: verify_js)
      rescue ConnectionError => e
        if attempts < max_attempts
          delay = retry_delay * attempts
          Logging.warn(
            "Connection attempt #{attempts}/#{max_attempts} failed: #{e.message}. " \
            "Retrying in #{delay}s...",
            tag: 'JetstreamBridge::Connection'
          )
          sleep(delay)
          retry
        else
          Logging.error(
            "Failed to establish connection after #{attempts} attempts",
            tag: 'JetstreamBridge::Connection'
          )
          cleanup_connection!
          raise
        end
      end
    end

    def establish_connection(servers, verify_js:)
      # Use mock NATS client if explicitly enabled for testing
      # This allows test helpers to inject a mock without affecting normal operation
      @nc = if defined?(JetstreamBridge::TestHelpers) &&
               JetstreamBridge::TestHelpers.respond_to?(:test_mode?) &&
               JetstreamBridge::TestHelpers.test_mode? &&
               JetstreamBridge.instance_variable_defined?(:@mock_nats_client)
              JetstreamBridge.instance_variable_get(:@mock_nats_client)
            else
              NATS::IO::Client.new
            end

      # Setup reconnect handler to refresh JetStream context
      @nc.on_reconnect do
        @reconnecting = true
        Logging.info(
          'NATS reconnected, refreshing JetStream context',
          tag: 'JetstreamBridge::Connection'
        )

        success = refresh_jetstream_with_retry?

        @reconnecting = false
        start_refresh_retry_loop unless success
      end

      @nc.on_disconnect do |reason|
        @state = State::DISCONNECTED
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

      # Only connect if not already connected (mock may be pre-connected)
      # Note: For test helpers mock, skip connect. For RSpec mocks, always call connect
      skip_connect = @nc.connected? &&
                     defined?(JetstreamBridge::TestHelpers) &&
                     JetstreamBridge::TestHelpers.respond_to?(:test_mode?) &&
                     JetstreamBridge::TestHelpers.test_mode?

      @nc.connect({ servers: servers }.merge(DEFAULT_CONN_OPTS)) unless skip_connect

      # Verify connection is established
      verify_connection!

      # Create JetStream context
      @jts = @nc.jetstream

      # Verify JetStream is available
      if verify_js
        verify_jetstream!
        if config_auto_provision
          Topology.provision!(@jts)
          Logging.info(
            'Topology ensured after connection (auto_provision=true).',
            tag: 'JetstreamBridge::Connection'
          )
        end
      else
        Logging.info(
          'Skipping JetStream account_info verification (auto_provision=false). ' \
          'Assuming JetStream is enabled.',
          tag: 'JetstreamBridge::Connection'
        )
      end

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

      # Re-ensure topology after reconnect when allowed
      if config_auto_provision
        Topology.provision!(@jts)
      else
        Logging.info(
          'Skipping topology provisioning after reconnect (auto_provision=false).',
          tag: 'JetstreamBridge::Connection'
        )
      end

      # Invalidate health check cache on successful reconnect
      @cached_health_status = nil
      @last_health_check = nil

      # Clear error state on successful reconnect
      @last_reconnect_error = nil
      @last_reconnect_error_at = nil
      @state = State::CONNECTED

      Logging.info(
        'JetStream context refreshed successfully after reconnect',
        tag: 'JetstreamBridge::Connection'
      )
    rescue StandardError => e
      # Store error state for diagnostics
      @last_reconnect_error = e
      @last_reconnect_error_at = Time.now
      @state = State::FAILED

      # Clear JetStream context but keep NATS connection alive for retry
      @jts = nil

      # Invalidate health check cache to force re-check
      @cached_health_status = false
      @last_health_check = Time.now.to_i

      Logging.error(
        "Failed to refresh JetStream context: #{e.class} #{e.message}",
        tag: 'JetstreamBridge::Connection'
      )

      # Re-raise so caller (on_reconnect handler) can retry
      raise
    end

    def refresh_jetstream_with_retry?(max_attempts: 3, base_delay: 0.5)
      attempts = 0
      while attempts < max_attempts
        attempts += 1
        begin
          refresh_jetstream_context
          return true
        rescue StandardError => e
          if attempts < max_attempts
            delay = refresh_retry_sleep_duration(attempts, base: base_delay)
            Logging.warn(
              "JetStream context refresh attempt #{attempts}/#{max_attempts} failed: #{e.message}. " \
              "Retrying in #{delay}s...",
              tag: 'JetstreamBridge::Connection'
            )
            sleep(delay)
          else
            Logging.error(
              "Failed to refresh JetStream context after #{attempts} attempts. " \
              'Starting background retry loop.',
              tag: 'JetstreamBridge::Connection'
            )
          end
        end
      end

      false
    end

    def start_refresh_retry_loop(initial_delay: REFRESH_RETRY_BASE_DELAY, max_attempts: REFRESH_RETRY_MAX_ATTEMPTS)
      return if @refresh_retry_thread&.alive?
      return unless @nc

      @refresh_retry_thread = Thread.new do
        Thread.current.report_on_exception = false
        attempts = 0
        delay = initial_delay

        while @nc&.connected?
          sleep(delay)
          attempts += 1
          break if max_attempts && attempts > max_attempts

          begin
            refresh_jetstream_context
            Logging.info(
              "JetStream context refreshed via background retry after #{attempts} attempt#{'s' if attempts != 1}",
              tag: 'JetstreamBridge::Connection'
            )
            break
          rescue StandardError => e
            if defined?(RSpec::Mocks::ExpiredTestDoubleError) &&
               e.is_a?(RSpec::Mocks::ExpiredTestDoubleError)
              Logging.debug(
                'Stopping background JetStream refresh due to expired test double',
                tag: 'JetstreamBridge::Connection'
              )
              break
            end
            delay = refresh_retry_sleep_duration(attempts + 1)
            Logging.warn(
              "Background JetStream refresh attempt #{attempts} failed: #{e.message}. " \
              "Retrying in #{delay}s...",
              tag: 'JetstreamBridge::Connection'
            )
          end
        end
      ensure
        @refresh_retry_thread = nil
      end
    rescue StandardError => e
      Logging.debug(
        "Could not start refresh retry loop: #{e.class} #{e.message}",
        tag: 'JetstreamBridge::Connection'
      )
    end

    def refresh_retry_sleep_duration(attempt, base: REFRESH_RETRY_BASE_DELAY)
      [base * (2**(attempt - 1)), REFRESH_RETRY_MAX_DELAY].min
    end

    # Expose for class-level helpers (not part of public API)
    attr_reader :nc

    def jetstream
      return @jts if @jts

      raise ConnectionNotEstablishedError,
            'JetStream context unavailable (refresh pending or failed)'
    end

    # Mask credentials in NATS URLs:
    # - "nats://user:pass@host:4222" -> "nats://user:***@host:4222"
    # - "nats://token@host:4222"     -> "nats://***@host:4222"
    def sanitize_urls(urls)
      urls.map { |u| Logging.sanitize_url(u) }
    end

    def cleanup_connection!(close_nc: true)
      begin
        # Avoid touching RSpec doubles used in unit tests
        is_rspec_double = defined?(RSpec::Mocks::Double) && @nc.is_a?(RSpec::Mocks::Double)
        @nc.close if !is_rspec_double && close_nc && @nc.respond_to?(:close) && @nc.connected?
      rescue StandardError
        # ignore cleanup errors
      end

      # Only clear connection references if we're closing the connection
      # When close_nc is false (e.g., during reconnect failures), keep @nc
      # so the connection can recover when NATS auto-reconnects
      if close_nc
        @nc = nil
        @jts = nil
        @connected_at = nil
      else
        # Clear JetStream context but keep NATS connection reference
        @jts = nil
      end

      if @refresh_retry_thread&.alive?
        @refresh_retry_thread.kill
        @refresh_retry_thread = nil
      end

      # Always invalidate health check cache
      @cached_health_status = nil
      @last_health_check = nil
    end

    def config_auto_provision
      cfg = JetstreamBridge.config
      cfg.respond_to?(:auto_provision) ? cfg.auto_provision : true
    rescue StandardError
      true
    end
  end
end

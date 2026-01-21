# frozen_string_literal: true

require_relative '../errors'

module JetstreamBridge
  # Configuration object for JetStream Bridge.
  #
  # Holds all configuration settings including NATS connection details,
  # application identifiers, reliability features, and consumer tuning.
  #
  # @example Basic configuration
  #   JetstreamBridge.configure do |config|
  #     config.nats_urls = "nats://localhost:4222"
  #     config.env = "production"
  #     config.app_name = "api_service"
  #     config.destination_app = "worker_service"
  #     config.use_outbox = true
  #     config.use_inbox = true
  #   end
  #
  # @example Using a preset
  #   JetstreamBridge.configure_for(:production) do |config|
  #     config.nats_urls = ENV["NATS_URLS"]
  #     config.app_name = "api"
  #     config.destination_app = "worker"
  #   end
  #
  class Config
    # Status constants for event processing states.
    module Status
      # Event queued in outbox, not yet published
      PENDING = 'pending'
      # Event currently being published to NATS
      PUBLISHING = 'publishing'
      # Event successfully published to NATS
      SENT = 'sent'
      # Event failed to publish after retries
      FAILED = 'failed'
      # Event received by consumer
      RECEIVED = 'received'
      # Event currently being processed by consumer
      PROCESSING = 'processing'
      # Event successfully processed by consumer
      PROCESSED = 'processed'
    end

    # NATS server URL(s), comma-separated for multiple servers
    # @return [String]
    attr_accessor :destination_app
    # NATS server URL(s)
    # @return [String]
    attr_accessor :nats_urls
    # Environment (unused in subjects; optional)
    attr_accessor :env
    # Application name for subject routing
    attr_accessor :app_name
    # Maximum delivery attempts before moving to DLQ
    # @return [Integer]
    attr_accessor :max_deliver
    # Time to wait for acknowledgment before redelivery
    # @return [String, Integer]
    attr_accessor :ack_wait
    # Backoff delays between retries
    # @return [Array<String>]
    attr_accessor :backoff
    # Enable transactional outbox pattern
    # @return [Boolean]
    attr_accessor :use_outbox
    # Enable idempotent inbox pattern
    # @return [Boolean]
    attr_accessor :use_inbox
    # ActiveRecord model class name for inbox events
    # @return [String]
    attr_accessor :inbox_model
    # ActiveRecord model class name for outbox events
    # @return [String]
    attr_accessor :outbox_model
    # Enable dead letter queue
    # @return [Boolean]
    attr_accessor :use_dlq
    # Logger instance
    # @return [Logger, nil]
    attr_accessor :logger
    # Applied preset name
    # @return [Symbol, nil]
    attr_reader :preset_applied
    # Number of retry attempts for initial connection
    # @return [Integer]
    attr_accessor :connect_retry_attempts
    # Delay between connection retry attempts (in seconds)
    # @return [Integer]
    attr_accessor :connect_retry_delay
    # Enable lazy connection (connect on first use instead of during configure)
    # @return [Boolean]
    attr_accessor :lazy_connect
    # Inbox prefix for request/reply (useful when NATS permissions restrict _INBOX.>)
    # @return [String, nil]
    attr_accessor :inbox_prefix
    # Skip JetStream management API calls (account_info, stream ensure, etc.)
    # Requires streams/consumers to be pre-provisioned and permissions handled externally.
    # @return [Boolean]
    attr_accessor :disable_js_api
    # Required stream name
    attr_accessor :stream_name
    # Optional durable consumer name
    attr_accessor :durable_name
    def initialize
      @nats_urls       = ENV['NATS_URLS'] || ENV['NATS_URL'] || 'nats://localhost:4222'
      env_from_env     = ENV['NATS_ENV']
      @env             = env_from_env
      @env_set         = !env_from_env.to_s.strip.empty?
      @app_name        = ENV['APP_NAME']  || 'app'
      @destination_app = ENV.fetch('DESTINATION_APP', nil)
      @stream_name     = ENV['STREAM_NAME']
      @stream_name_set = !@stream_name.nil?
      @durable_name    = ENV['DURABLE_NAME']

      @max_deliver = 5
      @ack_wait    = '30s'
      @backoff     = %w[1s 5s 15s 30s 60s]

      @use_outbox   = false
      @use_inbox    = false
      @use_dlq      = true
      @outbox_model = 'JetstreamBridge::OutboxEvent'
      @inbox_model  = 'JetstreamBridge::InboxEvent'
      @logger       = nil
      @preset_applied = nil

      # Connection management
      @connect_retry_attempts = 3
      @connect_retry_delay = 2
      @lazy_connect = false
      @inbox_prefix = ENV['NATS_INBOX_PREFIX'] || '_INBOX'
      @disable_js_api = (ENV['JETSTREAM_DISABLE_JS_API'] || 'true') == 'true'
      # Subjects are env-less by default; set env to nil/blank to keep compatibility with isolated clusters.
    end

    # Apply a configuration preset
    #
    # @param preset_name [Symbol, String] Name of preset (e.g., :production, :development)
    # @return [self]
    def apply_preset(preset_name)
      require_relative 'config_preset'
      ConfigPreset.apply(self, preset_name)
      @preset_applied = preset_name.to_sym
      self
    end

    # Get the JetStream stream name (required).
    #
    # Side-effect free query. Use validate! to ensure validity.
    #
    # @return [String, nil] Stream name
    def stream_name
      @cached_stream_name || (@stream_name_set ? @stream_name : default_stream_name)
    end

    # Get the NATS subject this application publishes to.
    #
    # Producer publishes to:   {app}.sync.{dest}
    # Consumer subscribes to:  {dest}.sync.{app}
    #
    # Side-effect free query. Use validate! to ensure validity.
    #
    # @return [String, nil] Source subject for publishing
    # @example
    #   config.app_name = "api"
    #   config.destination_app = "worker"
    #   config.source_subject  # => "api.sync.worker"
    def source_subject
      @cached_source_subject || build_source_subject
    end

    # Get the NATS subject this application subscribes to.
    #
    # Side-effect free query. Use validate! to ensure validity.
    #
    # @return [String, nil] Destination subject for consuming
    # @example
    #   config.app_name = "api"
    #   config.destination_app = "worker"
    #   config.destination_subject  # => "worker.sync.api"
    def destination_subject
      @cached_destination_subject || build_destination_subject
    end

    # Get the dead letter queue subject for this application.
    #
    # Each app has its own DLQ for better isolation and monitoring.
    #
    # Side-effect free query. Use validate! to ensure validity.
    #
    # @return [String, nil] DLQ subject in format "{app_name}.sync.dlq"
    # @example
    #   config.app_name = "api"
    #   config.dlq_subject  # => "api.sync.dlq"
    def dlq_subject
      @cached_dlq_subject || build_dlq_subject
    end

    # Get the durable consumer name for this application.
    #
    # @return [String] Durable name in format "{app_name}-workers"
    # @example
    #   config.app_name = "api"
    #   config.durable_name  # => "api-workers"
    def durable_name
      value = @durable_name
      return "#{app_name}-workers" if value.to_s.strip.empty?

      value
    end

    def env=(value)
      @env_set = !value.to_s.strip.empty? && value.to_s.strip != 'development'
      @env = value
    end

    def stream_name=(value)
      @stream_name_set = true
      @stream_name = value
    end

    # Validate all configuration settings.
    #
    # Checks that required settings are present and valid. Raises errors
    # for any invalid configuration. Caches computed subjects after validation.
    #
    # This is a command method - performs validation and updates internal state.
    # Call this once after configuration is complete.
    #
    # @return [true] If configuration is valid
    # @raise [ConfigurationError] If any validation fails
    # @example
    #   config.validate!  # Raises if destination_app is missing
    def validate!
      errors = []

      # Validate stream name
      stream_val = @stream_name_set ? @stream_name : default_stream_name
      if stream_val.to_s.strip.empty?
        errors << 'stream_name is required'
      else
        begin
          validate_stream_name!(stream_val)
        rescue InvalidSubjectError => e
          errors << e.message
        end
      end

      # Validate required fields
      errors << 'destination_app is required' if destination_app.to_s.strip.empty?
      errors << 'nats_urls is required' if nats_urls.to_s.strip.empty?
      errors << 'app_name is required' if app_name.to_s.strip.empty?
      errors << 'max_deliver must be >= 1' if max_deliver.to_i < 1
      errors << 'backoff must be an array' unless backoff.is_a?(Array)
      errors << 'backoff must not be empty' if backoff.is_a?(Array) && backoff.empty?
      errors << 'disable_js_api must be boolean' unless [true, false].include?(disable_js_api)

      # Validate inbox prefix
      begin
        validate_inbox_prefix!(inbox_prefix)
      rescue InvalidSubjectError => e
        errors << e.message
      end

      # Validate subject components
      begin
        validate_subject_component!(app_name, 'app_name') unless app_name.to_s.strip.empty?
        validate_subject_component!(destination_app, 'destination_app') unless destination_app.to_s.strip.empty?
      rescue InvalidSubjectError, MissingConfigurationError => e
        errors << e.message
      end

      raise ConfigurationError, "Configuration errors: #{errors.join(', ')}" if errors.any?

      # Cache computed values after successful validation
      cache_computed_values!

      true
    end

    private

    # Cache computed subjects after validation
    def cache_computed_values!
      @cached_stream_name = @stream_name_set ? @stream_name : default_stream_name
      @cached_source_subject = build_source_subject
      @cached_destination_subject = build_destination_subject
      @cached_dlq_subject = build_dlq_subject
    end

    # Build source subject without side effects
    def build_source_subject
      return nil if app_name.to_s.strip.empty? || destination_app.to_s.strip.empty?

      env_part = @env_set ? env.to_s.strip : ''
      return "#{env_part}.#{app_name}.sync.#{destination_app}" unless env_part.empty?

      "#{app_name}.sync.#{destination_app}"
    end

    # Build destination subject without side effects
    def build_destination_subject
      return nil if app_name.to_s.strip.empty? || destination_app.to_s.strip.empty?

      env_part = @env_set ? env.to_s.strip : ''
      return "#{env_part}.#{destination_app}.sync.#{app_name}" unless env_part.empty?

      "#{destination_app}.sync.#{app_name}"
    end

    # Build DLQ subject without side effects
    def build_dlq_subject
      return nil if app_name.to_s.strip.empty?

      env_part = @env_set ? env.to_s.strip : ''
      return "#{env_part}.#{app_name}.sync.dlq" unless env_part.empty?

      "#{app_name}.sync.dlq"
    end

    def validate_inbox_prefix!(value)
      str = value.to_s.strip
      raise InvalidSubjectError, 'inbox_prefix cannot be empty' if str.empty?

      # Disallow wildcards, spaces, or control characters in inbox prefix
      if str.match?(/[*> \t\r\n\x00-\x1F\x7F]/)
        raise InvalidSubjectError,
              "inbox_prefix contains invalid characters (wildcards, spaces, or control chars): #{value.inspect}"
      end
    end

    def validate_override!(name, value)
      str = value.to_s.strip
      raise InvalidSubjectError, "#{name} cannot be empty" if str.empty?
      if str.match?(/[ \t\r\n\x00-\x1F\x7F]/)
        raise InvalidSubjectError, "#{name} contains invalid whitespace/control characters: #{value.inspect}"
      end
    end

    def validate_stream_name!(value)
      str = value.to_s.strip
      raise MissingConfigurationError, 'stream_name is required' if str.empty?
      if str.match?(/[*> \t\r\n\x00-\x1F\x7F]/)
        raise InvalidSubjectError,
              "stream_name contains invalid characters (wildcards, whitespace, or control chars): #{value.inspect}"
      end
    end

    def default_stream_name
      nil
    end

    def validate_subject_component!(value, name)
      str = value.to_s.strip
      raise MissingConfigurationError, "#{name} cannot be empty" if str.empty?

      # NATS subject tokens must not contain wildcards, spaces, or control characters
      # Valid characters: alphanumeric, hyphen, underscore
      if str.match?(/[.*>\s\x00-\x1F\x7F]/)
        raise InvalidSubjectError,
              "#{name} contains invalid NATS subject characters (wildcards, spaces, or control chars): #{value.inspect}"
      end

      # NATS has a practical subject length limit
      return unless str.length > 255

      raise InvalidSubjectError, "#{name} exceeds maximum length (255 characters): #{str.length}"
    end
  end
end

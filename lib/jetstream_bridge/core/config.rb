# frozen_string_literal: true

require_relative '../errors'

module JetstreamBridge
  # Configuration object for JetStream Bridge.
  #
  # Holds all configuration settings including NATS connection details,
  # application identifiers, reliability features, and consumer tuning.
  #
  # IMPORTANT: app_name should not include environment identifiers
  # (e.g., use "api" not "api-production") as consumer names are
  # shared across environments for the same application.
  #
  # @example Basic configuration
  #   JetstreamBridge.configure do |config|
  #     config.nats_urls = "nats://localhost:4222"
  #     config.app_name = "api_service"
  #     config.destination_app = "worker_service"
  #     config.stream_name = "jetstream-bridge-stream"
  #     config.use_outbox = true
  #     config.use_inbox = true
  #   end
  #
  # @example Using a preset
  #   JetstreamBridge.configure_for(:production) do |config|
  #     config.nats_urls = ENV["NATS_URLS"]
  #     config.app_name = "api"
  #     config.destination_app = "worker"
  #     config.stream_name = "jetstream-bridge-stream"
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

    # Destination application name for subject routing
    # @return [String]
    attr_accessor :destination_app
    # NATS server URL(s), comma-separated for multiple servers
    # @return [String]
    attr_accessor :nats_urls
    # JetStream stream name (required)
    # @return [String]
    attr_accessor :stream_name
    # Application name for subject routing and consumer naming.
    # Should not include environment identifiers (e.g., use "api" not "api-production").
    # @return [String]
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
    # Allow JetStream Bridge to create/update streams/consumers and call JetStream management APIs.
    # Disable for locked-down environments and handle provisioning separately.
    # @return [Boolean]
    attr_accessor :auto_provision
    # Consumer mode: :pull (default) or :push
    # Pull consumers require publishing to JetStream API subjects ($JS.API.CONSUMER.MSG.NEXT.*)
    # Push consumers receive messages automatically on a delivery subject
    # @return [Symbol]
    attr_accessor :consumer_mode
    # Delivery subject for push consumers (optional, defaults to {destination_subject}.worker)
    # Only used when consumer_mode is :push
    # @return [String, nil]
    attr_accessor :delivery_subject
    # Queue group / deliver_group for push consumers (optional, defaults to durable_name or app_name)
    # Only used when consumer_mode is :push. Determines how push consumers load-balance.
    # @return [String, nil]
    attr_accessor :push_consumer_group

    # Initialize a new Config with sensible defaults.
    #
    # Reads initial values from environment variables when available
    # (NATS_URLS, NATS_URL, JETSTREAM_STREAM_NAME, APP_NAME, DESTINATION_APP).
    #
    # @return [Config]
    def initialize
      @nats_urls       = ENV['NATS_URLS'] || ENV['NATS_URL'] || 'nats://localhost:4222'
      @stream_name     = ENV['JETSTREAM_STREAM_NAME'] || 'jetstream-bridge-stream'
      @app_name        = ENV['APP_NAME'] || 'app'
      @destination_app = ENV.fetch('DESTINATION_APP', nil)

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
      @auto_provision = true

      # Consumer mode
      @consumer_mode = :pull
      @delivery_subject = nil
      @push_consumer_group = nil
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

    # Get the NATS subject this application publishes to.
    #
    # Producer publishes to:   {app}.sync.{dest}
    # Consumer subscribes to:  {dest}.sync.{app}
    #
    # @return [String] Source subject for publishing
    # @raise [InvalidSubjectError] If components contain NATS wildcards
    # @raise [MissingConfigurationError] If required components empty
    # @example
    #   config.app_name = "api"
    #   config.destination_app = "worker"
    #   config.source_subject  # => "api.sync.worker"
    def source_subject
      validate_subject_component!(app_name, 'app_name')
      validate_subject_component!(destination_app, 'destination_app')
      "#{app_name}.sync.#{destination_app}"
    end

    # Get the NATS subject this application subscribes to.
    #
    # @return [String] Destination subject for consuming
    # @raise [InvalidSubjectError] If components contain NATS wildcards
    # @raise [MissingConfigurationError] If required components empty
    def destination_subject
      validate_subject_component!(app_name, 'app_name')
      validate_subject_component!(destination_app, 'destination_app')
      "#{destination_app}.sync.#{app_name}"
    end

    # Get the dead letter queue subject for this application.
    #
    # Each app has its own DLQ for better isolation and monitoring.
    #
    # @return [String] DLQ subject in format "{app_name}.sync.dlq"
    # @raise [InvalidSubjectError] If components contain NATS wildcards
    # @raise [MissingConfigurationError] If required components are empty
    def dlq_subject
      validate_subject_component!(app_name, 'app_name')
      "#{app_name}.sync.dlq"
    end

    # Get the durable consumer name for this application.
    #
    # Returns the app_name with "-workers" suffix. Consumer names are
    # shared across environments, so app_name should not include
    # environment identifiers (e.g., use "myapp" not "myapp-production").
    #
    # @return [String] Durable consumer name
    # @example
    #   config.app_name = "notifications"
    #   config.durable_name  # => "notifications-workers"
    #
    def durable_name
      "#{app_name}-workers"
    end

    # Get the delivery subject for push consumers.
    #
    # @return [String] Delivery subject for push consumers
    # @raise [InvalidSubjectError] If components contain NATS wildcards
    # @raise [MissingConfigurationError] If required components are empty
    def push_delivery_subject
      return delivery_subject if delivery_subject && !delivery_subject.empty?

      # Default: {destination_subject}.worker
      "#{destination_subject}.worker"
    end

    # Queue group for push consumers. Controls deliver_group and queue subscription.
    #
    # @return [String] Queue group name
    # @raise [InvalidSubjectError, MissingConfigurationError] If derived components invalid
    def push_consumer_group_name
      group = push_consumer_group
      group = durable_name if group.to_s.strip.empty?
      group = app_name if group.to_s.strip.empty?

      validate_subject_component!(group, 'push_consumer_group')
      group
    end

    # Check if using pull consumer mode.
    #
    # @return [Boolean]
    def pull_consumer?
      consumer_mode.to_sym == :pull
    rescue NoMethodError
      false
    end

    # Check if using push consumer mode.
    #
    # @return [Boolean]
    def push_consumer?
      consumer_mode.to_sym == :push
    rescue NoMethodError
      false
    end

    # Validate all configuration settings.
    #
    # Checks that required settings are present and valid. Raises errors
    # for any invalid configuration.
    #
    # @return [true] If configuration is valid
    # @raise [ConfigurationError] If any validation fails
    # @example
    #   config.validate!  # Raises if destination_app is missing
    def validate!
      errors = []
      validate_required_fields!(errors)
      validate_numeric_constraints!(errors)
      validate_backoff!(errors)
      validate_consumer_mode!(errors)
      validate_push_consumer!(errors)

      raise ConfigurationError, "Configuration errors: #{errors.join(', ')}" if errors.any?

      true
    end

    private

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

    def validate_required_fields!(errors)
      errors << 'destination_app is required' if destination_app.to_s.strip.empty?
      errors << 'nats_urls is required' if nats_urls.to_s.strip.empty?
      errors << 'stream_name is required' if stream_name.to_s.strip.empty?
      errors << 'app_name is required' if app_name.to_s.strip.empty?
    end

    def validate_numeric_constraints!(errors)
      errors << 'max_deliver must be >= 1' if max_deliver.to_i < 1
    end

    def validate_backoff!(errors)
      errors << 'backoff must be an array' unless backoff.is_a?(Array)
      errors << 'backoff must not be empty' if backoff.is_a?(Array) && backoff.empty?
    end

    def validate_consumer_mode!(errors)
      return errors << 'consumer_mode must be :pull or :push' if consumer_mode.nil?

      errors << 'consumer_mode must be :pull or :push' unless [:pull, :push].include?(consumer_mode.to_sym)
    end

    def validate_push_consumer!(errors)
      return unless push_consumer?

      push_consumer_group_name
    rescue ConfigurationError => e
      errors << e.message
    end
  end
end

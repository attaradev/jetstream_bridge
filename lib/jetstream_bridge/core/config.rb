# frozen_string_literal: true

require_relative '../errors'

module JetstreamBridge
  class Config
    # Status constants for clarity
    module Status
      PENDING = 'pending'
      PUBLISHING = 'publishing'
      SENT = 'sent'
      FAILED = 'failed'
      RECEIVED = 'received'
      PROCESSING = 'processing'
      PROCESSED = 'processed'
    end

    attr_accessor :destination_app, :nats_urls, :env, :app_name,
                  :max_deliver, :ack_wait, :backoff,
                  :use_outbox, :use_inbox, :inbox_model, :outbox_model,
                  :use_dlq, :logger
    attr_reader :preset_applied

    def initialize
      @nats_urls       = ENV['NATS_URLS'] || ENV['NATS_URL'] || 'nats://localhost:4222'
      @env             = ENV['NATS_ENV']  || 'development'
      @app_name        = ENV['APP_NAME']  || 'app'
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

    # Single stream name per env
    def stream_name
      "#{env}-jetstream-bridge-stream"
    end

    # Base subjects
    # Producer publishes to:   {env}.{app}.sync.{dest}
    # Consumer subscribes to:  {env}.{dest}.sync.{app}
    def source_subject
      validate_subject_component!(env, 'env')
      validate_subject_component!(app_name, 'app_name')
      validate_subject_component!(destination_app, 'destination_app')
      "#{env}.#{app_name}.sync.#{destination_app}"
    end

    def destination_subject
      validate_subject_component!(env, 'env')
      validate_subject_component!(app_name, 'app_name')
      validate_subject_component!(destination_app, 'destination_app')
      "#{env}.#{destination_app}.sync.#{app_name}"
    end

    # DLQ
    def dlq_subject
      validate_subject_component!(env, 'env')
      "#{env}.sync.dlq"
    end

    def durable_name
      "#{env}-#{app_name}-workers"
    end

    # Validate configuration settings
    def validate!
      errors = []
      errors << 'destination_app is required' if destination_app.to_s.strip.empty?
      errors << 'nats_urls is required' if nats_urls.to_s.strip.empty?
      errors << 'env is required' if env.to_s.strip.empty?
      errors << 'app_name is required' if app_name.to_s.strip.empty?
      errors << 'max_deliver must be >= 1' if max_deliver.to_i < 1
      errors << 'backoff must be an array' unless backoff.is_a?(Array)
      errors << 'backoff must not be empty' if backoff.is_a?(Array) && backoff.empty?

      raise ConfigurationError, "Configuration errors: #{errors.join(', ')}" if errors.any?

      true
    end

    private

    def validate_subject_component!(value, name)
      str = value.to_s
      if str.match?(/[.*>]/)
        raise InvalidSubjectError, "#{name} cannot contain NATS wildcards (., *, >): #{value.inspect}"
      end
      raise MissingConfigurationError, "#{name} cannot be empty" if str.strip.empty?
    end
  end
end

# frozen_string_literal: true

module JetstreamBridge
  # Configuration presets for common scenarios
  module ConfigPreset
    # Development preset: minimal features for fast local development
    #
    # @param config [Config] Configuration object to apply preset to
    def self.development(config)
      config.use_outbox = false
      config.use_inbox = false
      config.use_dlq = false
      config.max_deliver = 3
      config.ack_wait = '10s'
      config.backoff = %w[1s 2s 5s]
    end

    # Test preset: similar to development but with synchronous behavior
    #
    # @param config [Config] Configuration object to apply preset to
    def self.test(config)
      config.use_outbox = false
      config.use_inbox = false
      config.use_dlq = false
      config.max_deliver = 2
      config.ack_wait = '5s'
      config.backoff = %w[0.1s 0.5s]
    end

    # Production preset: all reliability features enabled
    #
    # @param config [Config] Configuration object to apply preset to
    def self.production(config)
      config.use_outbox = true
      config.use_inbox = true
      config.use_dlq = true
      config.max_deliver = 5
      config.ack_wait = '30s'
      config.backoff = %w[1s 5s 15s 30s 60s]
    end

    # Staging preset: production-like but with faster retries
    #
    # @param config [Config] Configuration object to apply preset to
    def self.staging(config)
      config.use_outbox = true
      config.use_inbox = true
      config.use_dlq = true
      config.max_deliver = 3
      config.ack_wait = '15s'
      config.backoff = %w[1s 5s 15s]
    end

    # High throughput preset: optimized for volume over reliability
    #
    # @param config [Config] Configuration object to apply preset to
    def self.high_throughput(config)
      config.use_outbox = false # Skip DB writes
      config.use_inbox = false # Skip deduplication
      config.use_dlq = true # But keep DLQ for visibility
      config.max_deliver = 3
      config.ack_wait = '10s'
      config.backoff = %w[1s 2s 5s]
    end

    # Maximum reliability preset: every safety feature enabled
    #
    # @param config [Config] Configuration object to apply preset to
    def self.maximum_reliability(config)
      config.use_outbox = true
      config.use_inbox = true
      config.use_dlq = true
      config.max_deliver = 10
      config.ack_wait = '60s'
      config.backoff = %w[1s 5s 15s 30s 60s 120s 300s 600s 1200s 1800s]
    end

    # Get available preset names
    #
    # @return [Array<Symbol>] List of available preset names
    def self.available_presets
      %i[development test production staging high_throughput maximum_reliability]
    end

    # Apply a preset by name
    #
    # @param config [Config] Configuration object
    # @param preset_name [Symbol, String] Name of preset to apply
    # @raise [ArgumentError] If preset name is unknown
    def self.apply(config, preset_name)
      preset_method = preset_name.to_sym
      unless available_presets.include?(preset_method)
        raise ArgumentError, "Unknown preset: #{preset_name}. Available: #{available_presets.join(', ')}"
      end

      public_send(preset_method, config)
    end
  end
end

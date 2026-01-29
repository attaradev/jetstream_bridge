# frozen_string_literal: true

require 'logger'
require_relative 'topology/topology'
require_relative 'consumer/subscription_manager'
require_relative 'core/logging'
require_relative 'core/config'
require_relative 'core/connection'

module JetstreamBridge
  # Dedicated provisioning orchestrator to keep connection concerns separate.
  #
  # Handles creating/updating stream topology and consumers. Can be used at
  # deploy-time with admin credentials or during runtime when auto_provision
  # is enabled.
  class Provisioner
    class << self
      # Provision both directions (A->B and B->A) with shared defaults.
      #
      # @param app_a [String] First app name
      # @param app_b [String] Second app name
      # @param stream_name [String] Stream used for both directions
      # @param nats_url [String] NATS connection URL
      # @param logger [Logger] Logger used for progress output
      # @param shared_config [Hash] Additional config applied to both directions
      #
      # @return [void]
      def provision_bidirectional!(
        app_a:,
        app_b:,
        stream_name: 'sync-stream',
        nats_url: ENV.fetch('NATS_URL', 'nats://nats:4222'),
        logger: Logger.new($stdout),
        **shared_config
      )
        [
          { app_name: app_a, destination_app: app_b },
          { app_name: app_b, destination_app: app_a }
        ].each do |direction|
          logger&.info "Provisioning #{direction[:app_name]} -> #{direction[:destination_app]}"
          configure_direction(direction, stream_name, nats_url, logger, shared_config)

          begin
            JetstreamBridge.startup!
            new.provision!
          ensure
            JetstreamBridge.shutdown!
          end
        end
      end

      def configure_direction(direction, stream_name, nats_url, logger, shared_config)
        JetstreamBridge.configure do |cfg|
          cfg.nats_urls = nats_url
          cfg.app_name = direction[:app_name]
          cfg.destination_app = direction[:destination_app]
          cfg.stream_name = stream_name
          cfg.auto_provision = true
          cfg.use_outbox = false
          cfg.use_inbox = false
          cfg.logger = logger if logger

          shared_config.each do |key, value|
            setter = "#{key}="
            cfg.public_send(setter, value) if cfg.respond_to?(setter)
          end
        end
      end
      private :configure_direction
    end

    def initialize(config: JetstreamBridge.config)
      @config = config
    end

    # Provision stream (and optionally consumer) with desired config.
    #
    # @param jts [Object, nil] Existing JetStream context (optional)
    # @param provision_consumer [Boolean] Whether to create/align the consumer too
    # @return [Object] JetStream context used for provisioning
    def provision!(jts: nil, provision_consumer: true)
      js = jts || Connection.connect!(verify_js: true)

      provision_stream!(jts: js)
      provision_consumer!(jts: js) if provision_consumer

      Logging.info(
        "Provisioned stream=#{@config.stream_name} consumer=#{@config.durable_name if provision_consumer}",
        tag: 'JetstreamBridge::Provisioner'
      )

      js
    end

    # Provision stream only.
    #
    # @param jts [Object, nil] Existing JetStream context (optional)
    # @return [Object] JetStream context used
    def provision_stream!(jts: nil)
      js = jts || Connection.connect!(verify_js: true)
      Topology.provision!(js)
      Logging.info(
        "Stream provisioned: #{@config.stream_name}",
        tag: 'JetstreamBridge::Provisioner'
      )
      js
    end

    # Provision durable consumer only.
    #
    # @param jts [Object, nil] Existing JetStream context (optional)
    # @return [Object] JetStream context used
    def provision_consumer!(jts: nil)
      js = jts || Connection.connect!(verify_js: true)
      SubscriptionManager.new(js, @config.durable_name, @config).ensure_consumer!(force: true)
      Logging.info(
        "Consumer provisioned: #{@config.durable_name}",
        tag: 'JetstreamBridge::Provisioner'
      )
      js
    end
  end
end

# frozen_string_literal: true

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
    def initialize(config: JetstreamBridge.config)
      @config = config
    end

    # Ensure stream (and optionally consumer) exist with desired config.
    #
    # @param jts [Object, nil] Existing JetStream context (optional)
    # @param ensure_consumer [Boolean] Whether to create/align the consumer too
    # @return [Object] JetStream context used for provisioning
    def ensure!(jts: nil, ensure_consumer: true)
      js = jts || Connection.connect!(verify_js: true)

      ensure_stream!(js)
      ensure_consumer!(js) if ensure_consumer

      Logging.info(
        "Provisioned stream=#{@config.stream_name} consumer=#{@config.durable_name if ensure_consumer}",
        tag: 'JetstreamBridge::Provisioner'
      )

      js
    end

    # Ensure stream only.
    #
    # @param jts [Object, nil] Existing JetStream context (optional)
    # @return [Object] JetStream context used
    def ensure_stream!(jts: nil)
      js = jts || Connection.connect!(verify_js: true)
      Topology.ensure!(js)
      Logging.info(
        "Stream ensured: #{@config.stream_name}",
        tag: 'JetstreamBridge::Provisioner'
      )
      js
    end

    # Ensure durable consumer only.
    #
    # @param jts [Object, nil] Existing JetStream context (optional)
    # @return [Object] JetStream context used
    def ensure_consumer!(jts: nil)
      js = jts || Connection.connect!(verify_js: true)
      SubscriptionManager.new(js, @config.durable_name, @config).ensure_consumer!(force: true)
      Logging.info(
        "Consumer ensured: #{@config.durable_name}",
        tag: 'JetstreamBridge::Provisioner'
      )
      js
    end
  end
end

# frozen_string_literal: true

require_relative 'publisher/publisher'
require_relative 'consumer/consumer'

module JetstreamBridge
  # Factory for creating Publisher instances with injected dependencies
  class PublisherFactory
    def initialize(connection_manager, config)
      @connection_manager = connection_manager
      @config = config
    end

    # Create a new Publisher instance
    #
    # @param retry_strategy [RetryStrategy, nil] Optional custom retry strategy
    # @return [Publisher] Configured publisher instance
    def create(retry_strategy: nil)
      Publisher.new(
        connection: @connection_manager.jetstream,
        config: @config,
        retry_strategy: retry_strategy
      )
    end
  end

  # Factory for creating Consumer instances with injected dependencies
  class ConsumerFactory
    def initialize(connection_manager, config)
      @connection_manager = connection_manager
      @config = config
    end

    # Create a new Consumer instance
    #
    # @param handler [Proc, #call] Message handler
    # @param durable_name [String, nil] Optional durable consumer name override
    # @param batch_size [Integer, nil] Optional batch size override
    # @return [Consumer] Configured consumer instance
    def create(handler, durable_name: nil, batch_size: nil, &block)
      Consumer.new(
        handler || block,
        connection: @connection_manager.jetstream,
        config: @config,
        durable_name: durable_name,
        batch_size: batch_size
      )
    end
  end
end

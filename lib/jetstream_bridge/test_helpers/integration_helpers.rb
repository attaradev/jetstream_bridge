# frozen_string_literal: true

module JetstreamBridge
  module TestHelpers
    # Integration helpers to exercise the mock NATS storage end-to-end.
    module IntegrationHelpers
      # Publish an event and wait for it to appear in mock storage
      #
      # @param event_attrs [Hash] Event attributes to publish
      # @param timeout [Integer] Maximum seconds to wait
      # @return [Models::PublishResult] Publish result
      # @raise [Timeout::Error] If event doesn't appear within timeout
      def publish_and_wait(timeout: 1, **event_attrs)
        result = JetstreamBridge.publish(**event_attrs)

        deadline = Time.now + timeout
        until Time.now > deadline
          storage = JetstreamBridge::TestHelpers.mock_storage
          break if storage.messages.any? { |m| m[:header]['nats-msg-id'] == result.event_id }

          sleep 0.01
        end

        result
      end

      # Consume events from mock storage
      #
      # @param batch_size [Integer] Number of events to consume
      # @yield [event] Block to handle each event
      # @return [Array<Hash>] Consumed events
      def consume_events(batch_size: 10, &handler)
        storage = JetstreamBridge::TestHelpers.mock_storage
        messages = storage.messages.first(batch_size)

        messages.each do |msg|
          event = JetstreamBridge::Models::Event.from_nats_message(
            OpenStruct.new(
              subject: msg[:subject],
              data: msg[:data],
              header: msg[:header],
              metadata: OpenStruct.new(
                sequence: OpenStruct.new(stream: msg[:sequence]),
                num_delivered: msg[:delivery_count],
                stream: 'test-stream',
                consumer: 'test-consumer'
              )
            )
          )

          handler&.call(event)
          JetstreamBridge::TestHelpers.record_consumed_event(event.to_h)
        end

        JetstreamBridge::TestHelpers.consumed_events
      end

      # Wait for a specific number of messages in mock storage
      #
      # @param count [Integer] Expected message count
      # @param timeout [Integer] Maximum seconds to wait
      # @return [Boolean] true if count reached, false if timeout
      def wait_for_messages(count, timeout: 2)
        deadline = Time.now + timeout
        storage = JetstreamBridge::TestHelpers.mock_storage

        until Time.now > deadline
          return true if storage.messages.size >= count

          sleep 0.01
        end

        false
      end
    end
  end
end

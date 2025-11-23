# frozen_string_literal: true

require 'time'

module JetstreamBridge
  module Models
    # Structured event object provided to consumers
    #
    # @example Accessing event data in consumer
    #   JetstreamBridge.subscribe do |event|
    #     puts event.type              # "user.created"
    #     puts event.payload.id        # 123
    #     puts event.resource_type     # "user"
    #     puts event.deliveries        # 1
    #     puts event.metadata.trace_id # "abc123"
    #   end
    class Event
      # Metadata associated with message delivery
      Metadata = Struct.new(
        :subject,
        :deliveries,
        :stream,
        :sequence,
        :consumer,
        :timestamp,
        keyword_init: true
      ) do
        def to_h
          {
            subject: subject,
            deliveries: deliveries,
            stream: stream,
            sequence: sequence,
            consumer: consumer,
            timestamp: timestamp
          }.compact
        end
      end

      # Payload accessor with method-style access
      class PayloadAccessor
        def initialize(payload)
          @payload = payload.is_a?(Hash) ? payload.transform_keys(&:to_s) : {}
        end

        def method_missing(method_name, *args)
          return @payload[method_name.to_s] if args.empty? && @payload.key?(method_name.to_s)

          super
        end

        def respond_to_missing?(method_name, _include_private = false)
          @payload.key?(method_name.to_s) || super
        end

        def [](key)
          @payload[key.to_s]
        end

        def dig(*keys)
          @payload.dig(*keys.map(&:to_s))
        end

        def to_h
          @payload
        end

        alias to_hash to_h
      end

      attr_reader :event_id, :type, :resource_type, :resource_id,
                  :producer, :occurred_at, :trace_id, :schema_version,
                  :metadata

      # @param envelope [Hash] The raw event envelope
      # @param metadata [Hash] Message delivery metadata
      def initialize(envelope, metadata: {})
        envelope = envelope.transform_keys(&:to_s) if envelope.respond_to?(:transform_keys)

        @event_id = envelope['event_id']
        @type = envelope['event_type']
        @resource_type = envelope['resource_type']
        @resource_id = envelope['resource_id']
        @producer = envelope['producer']
        @schema_version = envelope['schema_version'] || 1
        @trace_id = envelope['trace_id']

        @occurred_at = parse_time(envelope['occurred_at'])
        @payload = PayloadAccessor.new(envelope['payload'] || {})
        @metadata = build_metadata(metadata)
        @raw_envelope = envelope

        freeze
      end

      # Access payload with method-style syntax
      #
      # @example
      #   event.payload.user_id  # Same as event.payload["user_id"]
      #   event.payload.to_h     # Get raw payload hash
      attr_reader :payload

      # Get raw envelope hash
      #
      # @return [Hash] The original envelope
      def to_envelope
        @raw_envelope
      end

      # Get hash representation
      #
      # @return [Hash] Event as hash
      def to_h
        {
          event_id: @event_id,
          type: @type,
          resource_type: @resource_type,
          resource_id: @resource_id,
          producer: @producer,
          occurred_at: @occurred_at&.iso8601,
          trace_id: @trace_id,
          schema_version: @schema_version,
          payload: @payload.to_h,
          metadata: @metadata.to_h
        }
      end

      alias to_hash to_h

      # Number of times this message has been delivered
      #
      # @return [Integer] Delivery count
      def deliveries
        @metadata.deliveries || 1
      end

      # Subject this message was received on
      #
      # @return [String] NATS subject
      def subject
        @metadata.subject
      end

      # Stream this message came from
      #
      # @return [String, nil] Stream name
      def stream
        @metadata.stream
      end

      # Message sequence number in the stream
      #
      # @return [Integer, nil] Sequence number
      def sequence
        @metadata.sequence
      end

      def inspect
        "#<#{self.class.name} id=#{@event_id} type=#{@type} deliveries=#{deliveries}>"
      end

      # Support hash-like access for backwards compatibility
      def [](key)
        case key.to_s
        when 'event_id' then @event_id
        when 'event_type' then @type
        when 'resource_type' then @resource_type
        when 'resource_id' then @resource_id
        when 'producer' then @producer
        when 'occurred_at' then @occurred_at&.iso8601
        when 'trace_id' then @trace_id
        when 'schema_version' then @schema_version
        when 'payload' then @payload.to_h
        else
          @raw_envelope[key.to_s]
        end
      end

      private

      def build_metadata(meta)
        Metadata.new(
          subject: meta[:subject] || meta['subject'],
          deliveries: meta[:deliveries] || meta['deliveries'] || 1,
          stream: meta[:stream] || meta['stream'],
          sequence: meta[:sequence] || meta['sequence'],
          consumer: meta[:consumer] || meta['consumer'],
          timestamp: Time.now.utc
        )
      end

      def parse_time(value)
        return nil if value.nil?
        return value if value.is_a?(Time)

        Time.parse(value.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end

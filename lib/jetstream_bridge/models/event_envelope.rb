# frozen_string_literal: true

require 'securerandom'
require 'time'

module JetstreamBridge
  module Models
    # Immutable value object representing an event envelope.
    #
    # Encapsulates all fields of a JetStream Bridge event and freezes itself
    # (including the payload) after construction for thread-safety.
    class EventEnvelope
      # Current envelope schema version
      SCHEMA_VERSION = 1

      # @return [String] Unique event identifier (UUID)
      # @return [Integer] Envelope schema version
      # @return [String] Event type (e.g. "created", "updated")
      # @return [String] Name of the producing application
      # @return [String] Resource type (e.g. "user", "order")
      # @return [String] Resource identifier extracted from payload
      # @return [Time] When the event occurred
      # @return [String] Distributed trace identifier
      # @return [Hash] Frozen event payload
      attr_reader :event_id, :schema_version, :event_type, :producer,
                  :resource_type, :resource_id, :occurred_at, :trace_id, :payload

      # Build a new EventEnvelope.
      #
      # @param resource_type [String] Resource type (e.g. "user")
      # @param event_type [String] Event type (e.g. "created")
      # @param payload [Hash] Event payload data
      # @param event_id [String, nil] Custom event ID (auto-generated UUID if nil)
      # @param occurred_at [Time, String, nil] Event timestamp (defaults to now)
      # @param trace_id [String, nil] Distributed trace ID (auto-generated if nil)
      # @param producer [String, nil] Producer app name (defaults to config.app_name)
      # @param resource_id [String, nil] Resource ID (extracted from payload if nil)
      # @raise [ArgumentError] If required fields are blank
      def initialize(
        resource_type:,
        event_type:,
        payload:,
        event_id: nil,
        occurred_at: nil,
        trace_id: nil,
        producer: nil,
        resource_id: nil
      )
        @event_id = event_id || SecureRandom.uuid
        @schema_version = SCHEMA_VERSION
        @event_type = event_type.to_s
        @producer = producer || JetstreamBridge.config.app_name
        @resource_type = resource_type.to_s
        @resource_id = resource_id || extract_resource_id(payload)
        @occurred_at = parse_occurred_at(occurred_at)
        @trace_id = trace_id || SecureRandom.hex(8)
        @payload = deep_freeze(payload)

        validate!
        freeze
      end

      # Convert to hash for serialization.
      #
      # @return [Hash] Envelope fields as a symbol-keyed hash
      def to_h
        hash = {
          event_id: @event_id,
          schema_version: @schema_version,
          event_type: @event_type,
          producer: @producer,
          resource_type: @resource_type,
          occurred_at: format_time(@occurred_at),
          payload: @payload
        }

        # Only include optional fields if they have values
        hash[:resource_id] = @resource_id if @resource_id && !@resource_id.to_s.empty?
        hash[:trace_id] = @trace_id if @trace_id && !@trace_id.to_s.empty?

        hash
      end

      # Reconstruct an EventEnvelope from a hash (e.g. deserialized JSON).
      #
      # @param hash [Hash] String- or symbol-keyed envelope data
      # @return [EventEnvelope]
      def self.from_h(hash)
        new(
          event_id: hash['event_id'] || hash[:event_id],
          event_type: hash['event_type'] || hash[:event_type],
          producer: hash['producer'] || hash[:producer],
          resource_type: hash['resource_type'] || hash[:resource_type],
          resource_id: hash['resource_id'] || hash[:resource_id],
          occurred_at: parse_time(hash['occurred_at'] || hash[:occurred_at]),
          trace_id: hash['trace_id'] || hash[:trace_id],
          payload: hash['payload'] || hash[:payload] || {}
        )
      end

      def ==(other)
        other.is_a?(EventEnvelope) && event_id == other.event_id
      end

      alias eql? ==

      def hash
        event_id.hash
      end

      private

      def extract_resource_id(payload)
        return '' unless payload.respond_to?(:[])

        (payload['id'] || payload[:id]).to_s
      end

      def validate!
        raise ArgumentError, 'event_type cannot be blank' if @event_type.empty?
        raise ArgumentError, 'resource_type cannot be blank' if @resource_type.empty?
        raise ArgumentError, 'payload cannot be nil' if @payload.nil?
      end

      def parse_occurred_at(value)
        return Time.now.utc if value.nil?
        return value if value.is_a?(Time)

        Time.parse(value.to_s)
      rescue ArgumentError
        Time.now.utc
      end

      def format_time(time)
        time.is_a?(Time) ? time.iso8601 : time.to_s
      end

      def deep_freeze(obj)
        case obj
        when Hash
          obj.each do |k, v|
            deep_freeze(k)
            deep_freeze(v)
          end
          obj.freeze
        when Array
          obj.each { |item| deep_freeze(item) }
          obj.freeze
        else
          obj.freeze if obj.respond_to?(:freeze)
        end
        obj
      end

      def self.parse_time(value)
        return value if value.is_a?(Time)
        return Time.now.utc if value.nil?

        Time.parse(value.to_s)
      rescue ArgumentError
        Time.now.utc
      end
    end
  end
end

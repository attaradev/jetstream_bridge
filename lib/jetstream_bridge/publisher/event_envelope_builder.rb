# frozen_string_literal: true

require 'securerandom'
require 'time'

module JetstreamBridge
  # Builds event envelopes for publishing
  #
  # Single responsibility: Convert event parameters into a valid envelope hash.
  # All envelope construction logic is centralized here.
  class EventEnvelopeBuilder
    # Build an event envelope from parameters
    #
    # @param event_type [String] Event type (e.g., 'created', 'user.created')
    # @param payload [Hash] Event payload data
    # @param resource_type [String, nil] Resource type (inferred from event_type if nil)
    # @param options [Hash] Optional envelope fields
    # @option options [String] :event_id Custom event ID (auto-generated if not provided)
    # @option options [String] :producer Producer name (defaults to app_name from config)
    # @option options [String, Time] :occurred_at Event timestamp (defaults to current time)
    # @option options [String] :trace_id Distributed trace ID (auto-generated if not provided)
    # @option options [String] :resource_id Resource ID (extracted from payload if not provided)
    # @option options [Integer] :schema_version Schema version (defaults to 1)
    #
    # @return [Hash] Complete event envelope
    # @raise [ArgumentError] If required parameters are missing
    def self.build(event_type:, payload:, resource_type: nil, **options)
      new(event_type, payload, resource_type, options).build
    end

    def initialize(event_type, payload, resource_type, options)
      @event_type = event_type.to_s
      @payload = payload
      @resource_type = resource_type
      @options = options

      validate_required!
    end

    def build
      {
        'event_id' => event_id,
        'schema_version' => schema_version,
        'event_type' => @event_type,
        'producer' => producer,
        'resource_type' => resource_type,
        'resource_id' => resource_id,
        'occurred_at' => occurred_at,
        'trace_id' => trace_id,
        'payload' => @payload
      }
    end

    private

    def validate_required!
      raise ArgumentError, 'event_type is required' if @event_type.empty?
      raise ArgumentError, 'payload is required' if @payload.nil?
    end

    def event_id
      @options[:event_id] || SecureRandom.uuid
    end

    def schema_version
      @options[:schema_version] || 1
    end

    def producer
      @options[:producer] || JetstreamBridge.config.app_name
    end

    def resource_type
      @resource_type || infer_resource_type || 'event'
    end

    def infer_resource_type
      # Extract from "user.created" -> "user"
      @event_type.split('.').first if @event_type.include?('.')
    end

    def resource_id
      @options[:resource_id] || extract_resource_id_from_payload
    end

    def extract_resource_id_from_payload
      return '' unless @payload.respond_to?(:[])

      payload_normalized = @payload.transform_keys(&:to_s) if @payload.respond_to?(:transform_keys)
      payload_normalized ||= @payload

      (payload_normalized['id'] || payload_normalized[:id] ||
       payload_normalized['resource_id'] || payload_normalized[:resource_id]).to_s
    end

    def occurred_at
      value = @options[:occurred_at]
      return Time.now.utc.iso8601 if value.nil?
      return value.iso8601 if value.is_a?(Time)

      Time.parse(value.to_s).iso8601
    rescue ArgumentError
      Time.now.utc.iso8601
    end

    def trace_id
      @options[:trace_id] || SecureRandom.hex(8)
    end
  end
end

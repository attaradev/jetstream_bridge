# frozen_string_literal: true

module JetstreamBridge
  module Models
    # Result object returned from publish operations
    #
    # @example Checking result status
    #   result = JetstreamBridge.publish(event_type: "user.created", payload: { id: 1 })
    #   if result.success?
    #     puts "Published with event_id: #{result.event_id}"
    #   else
    #     puts "Failed: #{result.error.message}"
    #   end
    class PublishResult
      attr_reader :event_id, :subject, :error, :duplicate

      # @param success [Boolean] Whether the publish was successful
      # @param event_id [String] The event ID that was published
      # @param subject [String] The NATS subject the event was published to
      # @param error [Exception, nil] Any error that occurred
      # @param duplicate [Boolean] Whether NATS detected this as a duplicate
      def initialize(success:, event_id:, subject:, error: nil, duplicate: false)
        @success = success
        @event_id = event_id
        @subject = subject
        @error = error
        @duplicate = duplicate
        freeze
      end

      # @return [Boolean] True if the publish was successful
      def success?
        @success
      end

      # @return [Boolean] True if the publish failed
      def failure?
        !@success
      end

      # @return [Boolean] True if NATS detected this as a duplicate message
      def duplicate?
        @duplicate
      end

      # @return [Hash] Hash representation of the result
      def to_h
        {
          success: @success,
          event_id: @event_id,
          subject: @subject,
          duplicate: @duplicate,
          error: @error&.message
        }
      end

      alias to_hash to_h

      def inspect
        "#<#{self.class.name} success=#{@success} event_id=#{@event_id} duplicate=#{@duplicate}>"
      end
    end
  end
end

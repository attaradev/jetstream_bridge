# frozen_string_literal: true

require 'securerandom'

module JetstreamBridge
  # Immutable per-message metadata
  MessageContext = Struct.new(
    :event_id, :deliveries, :subject, :seq, :consumer, :stream,
    keyword_init: true
  ) do
    def self.build(msg)
      new(
        event_id:   msg.header&.[]('nats-msg-id') || SecureRandom.uuid,
        deliveries: msg.metadata&.num_delivered.to_i,
        subject:    msg.subject,
        seq:        msg.metadata&.sequence,
        consumer:   msg.metadata&.consumer,
        stream:     msg.metadata&.stream
      )
    end
  end
end

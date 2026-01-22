# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'Publisher#publish_envelope' do
  let(:mock_jts) { double('jetstream') }
  let(:config) do
    JetstreamBridge::Config.new.tap do |c|
      c.nats_urls = 'nats://localhost:4222'
      c.app_name = 'test_app'
      c.destination_app = 'worker'
      c.stream_name = 'TEST'
      c.validate!
    end
  end

  let(:publisher) do
    JetstreamBridge::Publisher.new(
      connection: mock_jts,
      config: config
    )
  end

  let(:valid_envelope) do
    {
      'event_id' => SecureRandom.uuid,
      'schema_version' => 1,
      'event_type' => 'user.created',
      'producer' => 'external-system',
      'resource_type' => 'user',
      'resource_id' => '123',
      'occurred_at' => Time.now.utc.iso8601,
      'trace_id' => SecureRandom.hex(8),
      'payload' => { id: 123, name: 'Alice' }
    }
  end

  let(:mock_ack) do
    double('ack', duplicate?: false, error: nil, respond_to?: true)
  end

  describe '#publish_envelope' do
    it 'publishes a complete envelope' do
      allow(mock_jts).to receive(:publish).and_return(mock_ack)

      result = publisher.publish_envelope(valid_envelope)

      expect(result.success?).to be true
      expect(result.event_id).to eq(valid_envelope['event_id'])
      expect(mock_jts).to have_received(:publish).with(
        config.source_subject,
        kind_of(String),
        header: { 'nats-msg-id' => valid_envelope['event_id'] }
      )
    end

    it 'validates required fields' do
      incomplete_envelope = valid_envelope.except('event_id')

      expect do
        publisher.publish_envelope(incomplete_envelope)
      end.to raise_error(ArgumentError, /missing required fields.*event_id/)
    end

    it 'validates all required fields' do
      required_fields = %w[event_id schema_version event_type producer resource_type
                           resource_id occurred_at trace_id payload]

      required_fields.each do |field|
        incomplete_envelope = valid_envelope.except(field)

        expect do
          publisher.publish_envelope(incomplete_envelope)
        end.to raise_error(ArgumentError, /missing required fields.*#{field}/)
      end
    end

    it 'allows custom subject override' do
      allow(mock_jts).to receive(:publish).and_return(mock_ack)

      publisher.publish_envelope(valid_envelope, subject: 'custom.subject')

      expect(mock_jts).to have_received(:publish).with(
        'custom.subject',
        anything,
        anything
      )
    end

    it 'uses configured source_subject by default' do
      allow(mock_jts).to receive(:publish).and_return(mock_ack)

      publisher.publish_envelope(valid_envelope)

      expect(mock_jts).to have_received(:publish).with(
        config.source_subject,
        anything,
        anything
      )
    end

    it 'returns failure result on publish error' do
      allow(mock_jts).to receive(:publish).and_raise(StandardError.new('NATS error'))

      result = publisher.publish_envelope(valid_envelope)

      expect(result.success?).to be false
      expect(result.error).to be_a(StandardError)
      expect(result.error.message).to eq('NATS error')
    end

    it 'handles envelopes from external systems' do
      external_envelope = {
        'event_id' => 'external-123',
        'schema_version' => 1,
        'event_type' => 'payment.completed',
        'producer' => 'payment-service',
        'resource_type' => 'payment',
        'resource_id' => 'pay_456',
        'occurred_at' => '2024-01-01T12:00:00Z',
        'trace_id' => 'trace_789',
        'payload' => { amount: 99.99, currency: 'USD' }
      }

      allow(mock_jts).to receive(:publish).and_return(mock_ack)

      result = publisher.publish_envelope(external_envelope)

      expect(result.success?).to be true
      expect(result.event_id).to eq('external-123')
    end
  end
end

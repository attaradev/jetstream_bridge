# frozen_string_literal: true

require 'spec_helper'

RSpec.describe JetstreamBridge::EventEnvelopeBuilder do
  before do
    allow(JetstreamBridge).to receive(:config).and_return(
      double(app_name: 'test_app')
    )
  end

  describe '.build' do
    it 'builds envelope with required fields' do
      envelope = described_class.build(
        event_type: 'user.created',
        payload: { id: 1, email: 'test@example.com' }
      )

      expect(envelope['event_type']).to eq('user.created')
      expect(envelope['payload']).to eq({ id: 1, email: 'test@example.com' })
      expect(envelope['schema_version']).to eq(1)
      expect(envelope['producer']).to eq('test_app')
    end

    it 'infers resource_type from event_type' do
      envelope = described_class.build(
        event_type: 'user.created',
        payload: { id: 1 }
      )

      expect(envelope['resource_type']).to eq('user')
    end

    it 'uses explicit resource_type when provided' do
      envelope = described_class.build(
        event_type: 'created',
        payload: { id: 1 },
        resource_type: 'order'
      )

      expect(envelope['resource_type']).to eq('order')
    end

    it 'defaults resource_type to "event" if cannot infer' do
      envelope = described_class.build(
        event_type: 'created',
        payload: { id: 1 }
      )

      expect(envelope['resource_type']).to eq('event')
    end

    it 'extracts resource_id from payload id' do
      envelope = described_class.build(
        event_type: 'user.created',
        payload: { id: 123 }
      )

      expect(envelope['resource_id']).to eq('123')
    end

    it 'extracts resource_id from payload with string keys' do
      envelope = described_class.build(
        event_type: 'user.created',
        payload: { 'id' => 456 }
      )

      expect(envelope['resource_id']).to eq('456')
    end

    it 'uses explicit resource_id when provided' do
      envelope = described_class.build(
        event_type: 'user.created',
        payload: { id: 1 },
        resource_id: 'custom-id'
      )

      expect(envelope['resource_id']).to eq('custom-id')
    end

    it 'generates event_id if not provided' do
      envelope = described_class.build(
        event_type: 'user.created',
        payload: { id: 1 }
      )

      expect(envelope['event_id']).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
    end

    it 'uses provided event_id' do
      envelope = described_class.build(
        event_type: 'user.created',
        payload: { id: 1 },
        event_id: 'custom-event-id'
      )

      expect(envelope['event_id']).to eq('custom-event-id')
    end

    it 'generates trace_id if not provided' do
      envelope = described_class.build(
        event_type: 'user.created',
        payload: { id: 1 }
      )

      expect(envelope['trace_id']).to match(/\A[0-9a-f]{16}\z/i)
    end

    it 'uses provided trace_id' do
      envelope = described_class.build(
        event_type: 'user.created',
        payload: { id: 1 },
        trace_id: 'custom-trace-id'
      )

      expect(envelope['trace_id']).to eq('custom-trace-id')
    end

    it 'sets occurred_at to current time if not provided' do
      freeze_time = Time.parse('2024-01-01 12:00:00 UTC')
      allow(Time).to receive(:now).and_return(freeze_time)

      envelope = described_class.build(
        event_type: 'user.created',
        payload: { id: 1 }
      )

      expect(envelope['occurred_at']).to eq(freeze_time.utc.iso8601)
    end

    it 'uses provided occurred_at Time' do
      time = Time.parse('2023-12-25 10:00:00 UTC')
      envelope = described_class.build(
        event_type: 'user.created',
        payload: { id: 1 },
        occurred_at: time
      )

      expect(envelope['occurred_at']).to eq(time.iso8601)
    end

    it 'parses occurred_at string' do
      envelope = described_class.build(
        event_type: 'user.created',
        payload: { id: 1 },
        occurred_at: '2023-12-25 10:00:00 UTC'
      )

      expect(envelope['occurred_at']).to eq(Time.parse('2023-12-25 10:00:00 UTC').iso8601)
    end

    it 'uses custom producer when provided' do
      envelope = described_class.build(
        event_type: 'user.created',
        payload: { id: 1 },
        producer: 'custom-producer'
      )

      expect(envelope['producer']).to eq('custom-producer')
    end

    it 'raises ArgumentError if event_type is missing' do
      expect {
        described_class.build(event_type: '', payload: { id: 1 })
      }.to raise_error(ArgumentError, /event_type is required/)
    end

    it 'raises ArgumentError if payload is missing' do
      expect {
        described_class.build(event_type: 'user.created', payload: nil)
      }.to raise_error(ArgumentError, /payload is required/)
    end
  end
end

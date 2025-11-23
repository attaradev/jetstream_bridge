# frozen_string_literal: true

require 'jetstream_bridge'
require 'oj'

RSpec.describe JetstreamBridge::Publisher do
  let(:jts) { double('jetstream') }
  let(:ack) { double('ack', duplicate?: false, error: nil) }
  subject(:publisher) { described_class.new }

  before do
    JetstreamBridge.reset!
    # Mock Connection.connect! before configure to prevent actual connection
    allow(JetstreamBridge::Connection).to receive(:connect!).and_return(jts)
    JetstreamBridge.configure do |c|
      c.destination_app = 'dest'
      c.app_name        = 'source'
      c.env             = 'test'
    end
    allow(jts).to receive(:publish).and_return(ack)
  end

  after { JetstreamBridge.reset! }

  let(:payload) { { 'id' => '1', 'name' => 'Ada' } }

  describe '#publish with structured parameters' do
    it 'publishes with nats-msg-id header matching envelope event_id' do
      expect(jts).to receive(:publish) do |subject, data, header:|
        envelope = Oj.load(data, mode: :strict)
        expect(subject).to eq('test.source.sync.dest')
        expect(header['nats-msg-id']).to eq(envelope['event_id'])
        ack
      end

      result = publisher.publish(resource_type: 'user', event_type: 'created', payload: payload)
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
      expect(result.event_id).to be_a(String)
      expect(result.subject).to eq('test.source.sync.dest')
    end
  end

  describe '#publish with hash envelope' do
    it 'publishes with event hash and infers resource_type from dot notation' do
      expect(jts).to receive(:publish) do |subject, data, header:|
        expect(header).to be_a(Hash)
        envelope = Oj.load(data, mode: :strict)
        expect(subject).to eq('test.source.sync.dest')
        expect(envelope['event_type']).to eq('user.created')
        expect(envelope['resource_type']).to eq('user')
        expect(envelope['payload']).to eq(payload)
        ack
      end

      result = publisher.publish(event_type: 'user.created', payload: payload)
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
    end

    it 'publishes with complete envelope hash' do
      event_hash = {
        event_type: 'created',
        resource_type: 'user',
        payload: payload,
        event_id: 'custom-id-123'
      }

      expect(jts).to receive(:publish) do |subject, data, header:|
        expect(header).to be_a(Hash)
        envelope = Oj.load(data, mode: :strict)
        expect(subject).to eq('test.source.sync.dest')
        expect(envelope['event_type']).to eq('created')
        expect(envelope['resource_type']).to eq('user')
        expect(envelope['event_id']).to eq('custom-id-123')
        ack
      end

      result = publisher.publish(event_hash)
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
    end

    it 'requires event_type in hash' do
      expect do
        publisher.publish(payload: payload)
      end.to raise_error(ArgumentError, /event_type is required/)
    end

    it 'requires payload in hash' do
      expect do
        publisher.publish(event_type: 'user.created')
      end.to raise_error(ArgumentError, /payload is required/)
    end
  end

  describe '#publish parameter validation' do
    it 'raises error when neither structured params nor hash provided' do
      expect do
        publisher.publish
      end.to raise_error(ArgumentError, /Either provide/)
    end

    it 'raises error when destination_app is not configured' do
      JetstreamBridge.configure { |c| c.destination_app = nil }
      expect do
        publisher.publish(resource_type: 'user', event_type: 'created', payload: payload)
      end.to raise_error(ArgumentError, /destination_app must be configured/)
    end
  end

  describe '#publish with custom subject' do
    it 'uses custom subject when provided' do
      expect(jts).to receive(:publish) do |subject, _data, header:|
        expect(subject).to eq('custom.subject')
        ack
      end

      result = publisher.publish(resource_type: 'user', event_type: 'created', payload: payload, subject: 'custom.subject')
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
    end

    it 'uses subject from options' do
      expect(jts).to receive(:publish) do |subject, _data, header:|
        expect(subject).to eq('options.subject')
        ack
      end

      event_hash = { event_type: 'created', payload: payload }
      result = publisher.publish(event_hash, subject: 'options.subject')
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
    end
  end

  describe '#publish with custom options' do
    it 'accepts custom event_id' do
      expect(jts).to receive(:publish) do |_subject, data, header:|
        envelope = Oj.load(data, mode: :strict)
        expect(envelope['event_id']).to eq('custom-event-id')
        expect(header['nats-msg-id']).to eq('custom-event-id')
        ack
      end

      result = publisher.publish(resource_type: 'user', event_type: 'created', payload: payload, event_id: 'custom-event-id')
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
    end

    it 'accepts custom occurred_at' do
      custom_time = Time.parse('2025-01-01 00:00:00 UTC')
      expect(jts).to receive(:publish) do |_subject, data, header:|
        envelope = Oj.load(data, mode: :strict)
        expect(envelope['occurred_at']).to eq(custom_time.iso8601)
        ack
      end

      result = publisher.publish(resource_type: 'user', event_type: 'created', payload: payload, occurred_at: custom_time)
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
    end

    it 'accepts custom trace_id' do
      expect(jts).to receive(:publish) do |_subject, data, header:|
        envelope = Oj.load(data, mode: :strict)
        expect(envelope['trace_id']).to eq('custom-trace-id')
        ack
      end

      result = publisher.publish(resource_type: 'user', event_type: 'created', payload: payload, trace_id: 'custom-trace-id')
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
    end
  end

  describe '#publish with ACK errors' do
    it 'logs warning when ack indicates duplicate' do
      duplicate_ack = double('ack', duplicate?: true, error: nil)
      allow(jts).to receive(:publish).and_return(duplicate_ack)

      result = publisher.publish(resource_type: 'user', event_type: 'created', payload: payload)
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
    end

    it 'logs error when ack has error' do
      error_ack = double('ack', duplicate?: false, error: 'some error')
      allow(jts).to receive(:publish).and_return(error_ack)

      result = publisher.publish(resource_type: 'user', event_type: 'created', payload: payload)
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.failure?).to be(true)
    end

    it 'handles ack without duplicate? method' do
      simple_ack = double('ack')
      allow(simple_ack).to receive(:respond_to?).with(:duplicate?).and_return(false)
      allow(simple_ack).to receive(:respond_to?).with(:error).and_return(false)
      allow(jts).to receive(:publish).and_return(simple_ack)

      result = publisher.publish(resource_type: 'user', event_type: 'created', payload: payload)
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
    end
  end

  describe '#publish error handling' do
    it 'catches and logs publish errors' do
      allow(jts).to receive(:publish).and_raise(StandardError, 'NATS error')

      result = publisher.publish(resource_type: 'user', event_type: 'created', payload: payload)
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.failure?).to be(true)
    end

    it 're-raises ArgumentError validation errors' do
      expect do
        publisher.publish(payload: payload)
      end.to raise_error(ArgumentError)
    end
  end

  describe '#publish with outbox enabled' do
    let(:outbox_repo) { instance_double(JetstreamBridge::OutboxRepository) }
    let(:record) { double('outbox_record') }

    before do
      JetstreamBridge.configure { |c| c.use_outbox = true }
      allow(JetstreamBridge::ModelUtils).to receive(:constantize).and_return(JetstreamBridge::OutboxEvent)
      allow(JetstreamBridge::ModelUtils).to receive(:ar_class?).and_return(true)
      allow(JetstreamBridge::OutboxRepository).to receive(:new).and_return(outbox_repo)
      allow(outbox_repo).to receive(:find_or_build).and_return(record)
      allow(outbox_repo).to receive(:already_sent?).and_return(false)
      allow(outbox_repo).to receive(:persist_pre)
      allow(outbox_repo).to receive(:persist_success)
      allow(outbox_repo).to receive(:persist_failure)
      allow(outbox_repo).to receive(:persist_exception)
    end

    it 'publishes via outbox when enabled' do
      expect(outbox_repo).to receive(:persist_pre).with(record, anything, anything)
      expect(jts).to receive(:publish).and_return(ack)
      expect(outbox_repo).to receive(:persist_success).with(record)

      result = publisher.publish(resource_type: 'user', event_type: 'created', payload: payload)
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
    end

    it 'skips publish if already sent' do
      allow(outbox_repo).to receive(:already_sent?).and_return(true)
      expect(jts).not_to receive(:publish)

      result = publisher.publish(resource_type: 'user', event_type: 'created', payload: payload)
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
    end

    it 'persists failure when publish returns false' do
      error_ack = double('ack', duplicate?: false, error: 'publish error')
      allow(jts).to receive(:publish).and_return(error_ack)
      expect(outbox_repo).to receive(:persist_failure).with(record, 'publish error')

      result = publisher.publish(resource_type: 'user', event_type: 'created', payload: payload)
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.failure?).to be(true)
    end

    it 'persists exception when publish raises error' do
      allow(jts).to receive(:publish).and_raise(StandardError, 'NATS error')
      expect(outbox_repo).to receive(:persist_exception).with(record, kind_of(StandardError))

      result = publisher.publish(resource_type: 'user', event_type: 'created', payload: payload)
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.failure?).to be(true)
    end

    it 'falls back to direct publish when outbox model is not ActiveRecord' do
      allow(JetstreamBridge::ModelUtils).to receive(:ar_class?).and_return(false)
      expect(jts).to receive(:publish).and_return(ack)

      result = publisher.publish(resource_type: 'user', event_type: 'created', payload: payload)
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
    end
  end

  describe 'resource_id extraction' do
    it 'extracts resource_id from payload[:id]' do
      expect(jts).to receive(:publish) do |_subject, data, header:|
        envelope = Oj.load(data, mode: :strict)
        expect(envelope['resource_id']).to eq('123')
        ack
      end

      result = publisher.publish(resource_type: 'user', event_type: 'created', payload: { id: 123 })
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
    end

    it 'extracts resource_id from payload["id"]' do
      expect(jts).to receive(:publish) do |_subject, data, header:|
        envelope = Oj.load(data, mode: :strict)
        expect(envelope['resource_id']).to eq('456')
        ack
      end

      result = publisher.publish(resource_type: 'user', event_type: 'created', payload: { 'id' => '456' })
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
    end

    it 'handles payload without id' do
      expect(jts).to receive(:publish) do |_subject, data, header:|
        envelope = Oj.load(data, mode: :strict)
        expect(envelope['resource_id']).to eq('')
        ack
      end

      result = publisher.publish(resource_type: 'user', event_type: 'created', payload: { name: 'Test' })
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
    end

    it 'extracts resource_id from payload with resource_id field' do
      expect(jts).to receive(:publish) do |_subject, data, header:|
        envelope = Oj.load(data, mode: :strict)
        expect(envelope['resource_id']).to eq('res-789')
        ack
      end

      event_hash = { event_type: 'user.created', payload: { resource_id: 'res-789' } }
      result = publisher.publish(event_hash)
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
    end

    it 'handles nil payload gracefully' do
      # This will raise because payload is required, but tests the extract_resource_id path
      expect do
        publisher.publish(event_type: 'test.event', payload: nil)
      end.to raise_error(ArgumentError, /payload is required/)
    end
  end

  describe 'envelope normalization' do
    it 'infers resource_type from dot notation' do
      expect(jts).to receive(:publish) do |_subject, data, header:|
        envelope = Oj.load(data, mode: :strict)
        expect(envelope['resource_type']).to eq('order')
        ack
      end

      result = publisher.publish(event_type: 'order.shipped', payload: payload)
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
    end

    it 'does not override explicit resource_type' do
      expect(jts).to receive(:publish) do |_subject, data, header:|
        envelope = Oj.load(data, mode: :strict)
        expect(envelope['resource_type']).to eq('custom')
        ack
      end

      event_hash = { event_type: 'order.shipped', resource_type: 'custom', payload: payload }
      result = publisher.publish(event_hash)
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
    end

    it 'uses "event" as default resource_type when no inference possible' do
      expect(jts).to receive(:publish) do |_subject, data, header:|
        envelope = Oj.load(data, mode: :strict)
        expect(envelope['resource_type']).to eq('event')
        ack
      end

      result = publisher.publish(event_type: 'something_happened', payload: payload)
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
    end

    it 'preserves custom schema_version' do
      expect(jts).to receive(:publish) do |_subject, data, header:|
        envelope = Oj.load(data, mode: :strict)
        expect(envelope['schema_version']).to eq(2)
        ack
      end

      event_hash = { event_type: 'user.created', payload: payload, schema_version: 2 }
      result = publisher.publish(event_hash)
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
    end

    it 'preserves custom producer' do
      expect(jts).to receive(:publish) do |_subject, data, header:|
        envelope = Oj.load(data, mode: :strict)
        expect(envelope['producer']).to eq('custom-producer')
        ack
      end

      event_hash = { event_type: 'user.created', payload: payload, producer: 'custom-producer' }
      result = publisher.publish(event_hash)
      expect(result).to be_a(JetstreamBridge::Models::PublishResult)
      expect(result.success?).to be(true)
    end
  end
end
